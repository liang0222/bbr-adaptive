#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'
export LC_ALL=C

VERSION="v5.0 Verified Adaptive"
OUR_CONF="/etc/sysctl.d/99-zz-bbr-adaptive.conf"
MODULE_CONF="/etc/modules-load.d/99-bbr-adaptive.conf"
WORK_DIR=""
EXTERNAL_TMP=""
WARNINGS=0

log() {
    printf '%s\n' "$*"
}

warn() {
    WARNINGS=$((WARNINGS + 1))
    printf 'WARN: %s\n' "$*" >&2
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

cleanup() {
    if [ -n "${EXTERNAL_TMP:-}" ] && [ -e "$EXTERNAL_TMP" ]; then
        rm -f "$EXTERNAL_TMP"
    fi
    if [ -n "${WORK_DIR:-}" ] && [ -d "$WORK_DIR" ]; then
        rm -rf "$WORK_DIR"
    fi
}

unexpected_error() {
    local exit_code=$1
    local line=$2

    trap - ERR
    printf 'ERROR: unexpected failure at line %s (exit %s)\n' "$line" "$exit_code" >&2
    exit "$exit_code"
}

trap cleanup EXIT
trap 'unexpected_error $? $LINENO' ERR

normalize_uint() {
    local name=$1
    local value=$2
    local fallback=$3
    local minimum=$4
    local maximum=$5
    local label=${6:-$name}

    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
        warn "$label must be an integer; using $fallback"
        value=$fallback
    fi
    if [ "$value" -lt "$minimum" ]; then
        warn "$label is below $minimum; using $minimum"
        value=$minimum
    elif [ "$value" -gt "$maximum" ]; then
        warn "$label is above $maximum; using $maximum"
        value=$maximum
    fi
    printf -v "$name" '%s' "$value"
}

normalize_bool() {
    local name=$1
    local value=$2
    local fallback=$3
    local label=${4:-$name}

    case "$value" in
        0|1) ;;
        *)
            warn "$label must be 0 or 1; using $fallback"
            value=$fallback
            ;;
    esac
    printf -v "$name" '%s' "$value"
}

RETR_PROBE_SECONDS=${RETR_PROBE_SECONDS:-5}
RETR_CONFIDENCE_MIN_OUT=${RETR_CONFIDENCE_MIN_OUT:-500}
ENABLE_ECN=${ENABLE_ECN:-1}
AUTO_INSTALL_DEPS=${AUTO_INSTALL_DEPS:-1}
RUN_SPEED_TEST=${RUN_SPEED_TEST:-1}
APPLY_QDISC_NOW=${APPLY_QDISC_NOW:-0}
normalize_uint RETR_PROBE_SECONDS "$RETR_PROBE_SECONDS" 5 2 30
normalize_uint RETR_CONFIDENCE_MIN_OUT "$RETR_CONFIDENCE_MIN_OUT" 500 100 1000000
normalize_bool ENABLE_ECN "$ENABLE_ECN" 1
normalize_bool AUTO_INSTALL_DEPS "$AUTO_INSTALL_DEPS" 1
normalize_bool RUN_SPEED_TEST "$RUN_SPEED_TEST" 1
normalize_bool APPLY_QDISC_NOW "$APPLY_QDISC_NOW" 0

ENABLE_IP_FORWARD_IS_SET=0
ENABLE_IP_FORWARD_VALUE=""
if [ "${ENABLE_IP_FORWARD+x}" = "x" ]; then
    ENABLE_IP_FORWARD_IS_SET=1
    ENABLE_IP_FORWARD_VALUE=$ENABLE_IP_FORWARD
    normalize_bool ENABLE_IP_FORWARD_VALUE "$ENABLE_IP_FORWARD_VALUE" 0 ENABLE_IP_FORWARD
fi

echo "=================================="
echo " BBR Adaptive ${VERSION}"
echo "=================================="

if [ "$(id -u)" -ne 0 ]; then
    die "run as root, for example: sudo bash bbr.sh"
fi

if [ "$(uname -s)" != "Linux" ]; then
    die "this script only supports Linux"
fi

if [ ! -d /proc/sys/net/ipv4 ]; then
    die "/proc/sys is unavailable; run this on the host, not in a restricted build environment"
fi

install_dependencies() {
    [ "$AUTO_INSTALL_DEPS" -eq 1 ] || return 0

    log "Installing missing runtime dependencies..."
    if command_exists apt-get; then
        DEBIAN_FRONTEND=noninteractive apt-get update || warn "apt-get update failed"
        DEBIAN_FRONTEND=noninteractive apt-get install -y \
            ca-certificates curl iproute2 iputils-ping procps coreutils || return 1
    elif command_exists dnf; then
        dnf install -y ca-certificates curl iproute iputils procps-ng coreutils || return 1
    elif command_exists yum; then
        yum install -y ca-certificates curl iproute iputils procps-ng coreutils || return 1
    elif command_exists apk; then
        apk add --no-cache ca-certificates curl iproute2 iputils procps coreutils || return 1
    else
        return 1
    fi
}

MISSING_TOOLS=()
for tool in awk grep sysctl mktemp install mv cp rm mkdir cat sleep date uname id; do
    if ! command_exists "$tool"; then
        MISSING_TOOLS+=("$tool")
    fi
done

for tool in curl ping ip tc; do
    if ! command_exists "$tool"; then
        MISSING_TOOLS+=("$tool")
    fi
done

if [ "${#MISSING_TOOLS[@]}" -gt 0 ]; then
    if ! install_dependencies; then
        warn "automatic dependency installation failed"
    fi
fi

for tool in awk grep sysctl mktemp install mv cp rm mkdir cat sleep date uname id; do
    command_exists "$tool" || die "missing required command: $tool"
done

if ! command_exists curl; then
    warn "curl is unavailable; bandwidth and generated retransmission probes will be skipped"
fi
if ! command_exists ping; then
    warn "ping is unavailable; ICMP loss, RTT, and jitter measurements will be skipped"
fi

WORK_DIR=$(mktemp -d /tmp/bbr-adaptive.XXXXXX) || die "cannot create a temporary directory"

if command_exists flock; then
    mkdir -p /run/lock
    exec 9>/run/lock/bbr-adaptive.lock
    flock -n 9 || die "another bbr.sh instance is already running"
fi

KERNEL_RELEASE=$(uname -r)
if [[ "$KERNEL_RELEASE" =~ ^([0-9]+)\.([0-9]+) ]]; then
    KERNEL_MAJOR=${BASH_REMATCH[1]}
    KERNEL_MINOR=${BASH_REMATCH[2]}
else
    die "cannot parse kernel release: $KERNEL_RELEASE"
fi

kernel_ge() {
    local need_major=$1
    local need_minor=$2

    [ "$KERNEL_MAJOR" -gt "$need_major" ] || {
        [ "$KERNEL_MAJOR" -eq "$need_major" ] && [ "$KERNEL_MINOR" -ge "$need_minor" ]
    }
}

if ! kernel_ge 4 9; then
    die "kernel $KERNEL_RELEASE is too old for BBR; Linux 4.9 or newer is required"
fi

if command_exists modprobe; then
    modprobe tcp_bbr 2>/dev/null || true
fi

AVAILABLE_CC=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
if ! printf '%s\n' "$AVAILABLE_CC" | grep -qw bbr; then
    die "kernel $KERNEL_RELEASE does not expose BBR (available: ${AVAILABLE_CC:-none})"
fi

mkdir -p /etc/sysctl.d
if command_exists modprobe; then
    mkdir -p /etc/modules-load.d
    printf 'tcp_bbr\n' > "$WORK_DIR/module.conf"
fi

CPU_CORE=1
if command_exists nproc; then
    CPU_CORE=$(nproc 2>/dev/null || printf '1')
elif [ -r /proc/cpuinfo ]; then
    CPU_CORE=$(awk '/^processor[[:space:]]*:/ { n++ } END { print n > 0 ? n : 1 }' /proc/cpuinfo)
fi
if ! [[ "$CPU_CORE" =~ ^[0-9]+$ ]] || [ "$CPU_CORE" -lt 1 ]; then
    CPU_CORE=1
fi

if [ "$CPU_CORE" -le 1 ]; then
    CPU_LEVEL="low"
    MODE_BACKLOG=4096
    MODE_SYN_BACKLOG=4096
    MODE_SOMAXCONN=4096
elif [ "$CPU_CORE" -le 2 ]; then
    CPU_LEVEL="medium"
    MODE_BACKLOG=8192
    MODE_SYN_BACKLOG=8192
    MODE_SOMAXCONN=8192
else
    CPU_LEVEL="high"
    MODE_BACKLOG=16384
    MODE_SYN_BACKLOG=16384
    MODE_SOMAXCONN=16384
fi
log "Kernel: $KERNEL_RELEASE"
log "CPU: $CPU_LEVEL ($CPU_CORE cores)"

CURRENT_QDISC_BEFORE=$(sysctl -n net.core.default_qdisc 2>/dev/null || true)

qdisc_usable() {
    local candidate=$1

    if command_exists modprobe; then
        modprobe "sch_${candidate}" 2>/dev/null || true
    fi
    if ! sysctl -w "net.core.default_qdisc=$candidate" >/dev/null 2>&1; then
        return 1
    fi
    if [ -n "$CURRENT_QDISC_BEFORE" ]; then
        sysctl -w "net.core.default_qdisc=$CURRENT_QDISC_BEFORE" >/dev/null 2>&1 || \
            die "tested qdisc $candidate but could not restore $CURRENT_QDISC_BEFORE"
    fi
    return 0
}

QDISC=""
for candidate in fq fq_codel; do
    if qdisc_usable "$candidate"; then
        QDISC=$candidate
        break
    fi
done
if [ -z "$QDISC" ]; then
    die "neither fq nor fq_codel can be selected by this kernel"
fi
log "Selected default qdisc: $QDISC"

float_gt() {
    awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN { exit !(a > b) }'
}

float_ge() {
    awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN { exit !(a >= b) }'
}

format_megabytes() {
    awk -v bytes="${1:-0}" 'BEGIN { printf "%.1f", bytes / 1048576 }'
}

CONNECT_TEST_URLS=(
    "https://speed.cloudflare.com/__down?bytes=32"
    "https://www.google.com/generate_204"
)
SPEED_URLS=(
    "https://speed.cloudflare.com/__down?bytes=20000000"
    "https://cachefly.cachefly.net/10mb.test"
    "https://proof.ovh.net/files/10Mb.dat"
)

NETWORK_FAMILY="none"
IPVER_FLAG=""
CONNECT_TEST_URL=""
if command_exists curl; then
    for family_flag in -4 -6; do
        for url in "${CONNECT_TEST_URLS[@]}"; do
            if curl "$family_flag" --fail --location --silent --show-error \
                --output /dev/null --connect-timeout 2 --max-time 5 "$url" 2>/dev/null; then
                IPVER_FLAG=$family_flag
                CONNECT_TEST_URL=$url
                if [ "$family_flag" = "-4" ]; then
                    NETWORK_FAMILY="ipv4"
                else
                    NETWORK_FAMILY="ipv6"
                fi
                break 2
            fi
        done
    done
fi

PROBE_V4=("1.1.1.1" "8.8.8.8" "9.9.9.9")
PROBE_V6=("2606:4700:4700::1111" "2001:4860:4860::8888" "2620:fe::fe")
PING_TARGET="none"
PING_HOST=""

if command_exists ping; then
    for host in "${PROBE_V4[@]}"; do
        if ping -c 1 -W 1 "$host" >/dev/null 2>&1; then
            PING_TARGET="ipv4"
            PING_HOST=$host
            break
        fi
    done
    if [ "$PING_TARGET" = "none" ]; then
        for host in "${PROBE_V6[@]}"; do
            if ping -6 -c 1 -W 1 "$host" >/dev/null 2>&1; then
                PING_TARGET="ipv6"
                PING_HOST=$host
                break
            fi
        done
    fi
fi

if [ "$NETWORK_FAMILY" = "none" ] && [ "$PING_TARGET" != "none" ]; then
    NETWORK_FAMILY=$PING_TARGET
    if [ "$PING_TARGET" = "ipv4" ]; then
        IPVER_FLAG="-4"
    else
        IPVER_FLAG="-6"
    fi
fi
log "Network: $NETWORK_FAMILY (ICMP probe: ${PING_HOST:-unavailable})"

net_ping() {
    local count=${1:-6}

    case "$PING_TARGET" in
        ipv4) ping -c "$count" -W 1 "$PING_HOST" 2>/dev/null ;;
        ipv6) ping -6 -c "$count" -W 1 "$PING_HOST" 2>/dev/null ;;
        *) return 1 ;;
    esac
}

parse_ping_avg() {
    awk -F '=' '/min\/avg\/max/ {
        gsub(/ ms/, "", $2)
        split($2, a, "/")
        print a[2]
    }'
}

parse_ping_jitter() {
    awk -F '=' '/min\/avg\/max/ {
        gsub(/ ms/, "", $2)
        split($2, a, "/")
        print a[4]
    }'
}

parse_ping_loss() {
    awk -F ',' '/packet loss/ {
        for (i = 1; i <= NF; i++) {
            if ($i ~ /packet loss/) {
                gsub(/^[ \t]+/, "", $i)
                split($i, a, "%")
                print a[1]
            }
        }
    }'
}

RTT_VALID=0
JITTER_VALID=0
LOSS_VALID=0
RTT=""
JITTER=""
LOSS=""
PING_SAMPLE=$(net_ping 6 || true)
if [ -n "$PING_SAMPLE" ]; then
    RTT=$(printf '%s\n' "$PING_SAMPLE" | parse_ping_avg)
    JITTER=$(printf '%s\n' "$PING_SAMPLE" | parse_ping_jitter)
    LOSS=$(printf '%s\n' "$PING_SAMPLE" | parse_ping_loss)
    [[ "$RTT" =~ ^[0-9]+([.][0-9]+)?$ ]] && RTT_VALID=1
    [[ "$JITTER" =~ ^[0-9]+([.][0-9]+)?$ ]] && JITTER_VALID=1
    [[ "$LOSS" =~ ^[0-9]+([.][0-9]+)?$ ]] && LOSS_VALID=1
fi

LATENCY_VALID=0
LATENCY=""
if command_exists curl && [ -n "$CONNECT_TEST_URL" ] && [ -n "$IPVER_FLAG" ]; then
    LATENCY_TOTAL=0
    LATENCY_SAMPLES=0
    for _ in 1 2 3; do
        CONNECT_SECONDS=""
        if CONNECT_SECONDS=$(curl "$IPVER_FLAG" --fail --location --silent --show-error \
            --output /dev/null --connect-timeout 2 --max-time 5 \
            --write-out '%{time_connect}' "$CONNECT_TEST_URL" 2>/dev/null); then
            if [[ "$CONNECT_SECONDS" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
                CONNECT_MS=$(awk -v seconds="$CONNECT_SECONDS" 'BEGIN { printf "%.0f", seconds * 1000 }')
                LATENCY_TOTAL=$((LATENCY_TOTAL + CONNECT_MS))
                LATENCY_SAMPLES=$((LATENCY_SAMPLES + 1))
            fi
        fi
    done
    if [ "$LATENCY_SAMPLES" -gt 0 ]; then
        LATENCY=$((LATENCY_TOTAL / LATENCY_SAMPLES))
        LATENCY_VALID=1
    fi
fi

RTT_DISPLAY="N/A"
JITTER_DISPLAY="N/A"
LOSS_DISPLAY="N/A"
LATENCY_DISPLAY="N/A"
[ "$RTT_VALID" -eq 1 ] && RTT_DISPLAY="${RTT}ms"
[ "$JITTER_VALID" -eq 1 ] && JITTER_DISPLAY="${JITTER}ms"
[ "$LOSS_VALID" -eq 1 ] && LOSS_DISPLAY="${LOSS}%"
[ "$LATENCY_VALID" -eq 1 ] && LATENCY_DISPLAY="${LATENCY}ms"
log "TCP connect latency: $LATENCY_DISPLAY"
log "ICMP RTT/loss/jitter: $RTT_DISPLAY / $LOSS_DISPLAY / $JITTER_DISPLAY"

SPEED_VALID=0
SPEED_MBPS=""
SPEED_SOURCE=""

measure_speed() {
    local url output curl_rc speed bytes duration http_code

    [ "$RUN_SPEED_TEST" -eq 1 ] || return 1
    command_exists curl || return 1
    [ -n "$IPVER_FLAG" ] || return 1

    for url in "${SPEED_URLS[@]}"; do
        output=""
        curl_rc=0
        output=$(curl "$IPVER_FLAG" --fail --location --silent --show-error \
            --output /dev/null --connect-timeout 3 --max-time 15 \
            --write-out '%{speed_download}|%{size_download}|%{time_total}|%{http_code}' \
            "$url" 2>/dev/null) || curl_rc=$?
        IFS='|' read -r speed bytes duration http_code <<< "$output"

        if [[ "${speed:-}" =~ ^[0-9]+([.][0-9]+)?$ ]] &&
            [[ "${bytes:-}" =~ ^[0-9]+([.][0-9]+)?$ ]] &&
            [[ "${duration:-}" =~ ^[0-9]+([.][0-9]+)?$ ]] &&
            [[ "${http_code:-}" =~ ^[23][0-9][0-9]$ ]] &&
            float_ge "$bytes" 1048576 && float_ge "$duration" 0.05 && float_gt "$speed" 0; then
            SPEED_MBPS=$(awk -v value="$speed" 'BEGIN { printf "%.1f", value * 8 / 1000000 }')
            SPEED_SOURCE=$url
            SPEED_VALID=1
            return 0
        fi

        if [ "$curl_rc" -ne 0 ]; then
            continue
        fi
    done
    return 1
}

measure_speed || true

if [ "$SPEED_VALID" -eq 1 ]; then
    if float_gt "$SPEED_MBPS" 700; then
        BANDWIDTH="high"
    elif float_gt "$SPEED_MBPS" 200; then
        BANDWIDTH="medium"
    else
        BANDWIDTH="low"
    fi
    SPEED_DISPLAY="${SPEED_MBPS} Mbps"
    log "Bandwidth: $SPEED_DISPLAY ($BANDWIDTH, source: $SPEED_SOURCE)"
else
    BANDWIDTH="unknown"
    SPEED_DISPLAY="N/A"
    log "Bandwidth: N/A (no valid transfer; no synthetic value will be used)"
fi

sysctl_path_for() {
    local key=$1
    printf '/proc/sys/%s\n' "${key//./\/}"
}

sysctl_supported() {
    [ -e "$(sysctl_path_for "$1")" ]
}

read_net_counter() {
    local file=$1
    local proto=$2
    local key=$3

    [ -r "$file" ] || return 0
    awk -v proto="${proto}:" -v key="$key" '
        $1 == proto && !seen_header {
            for (i = 2; i <= NF; i++) idx[$i] = i
            seen_header = 1
            next
        }
        $1 == proto && seen_header {
            if (key in idx) print $idx[key]
            exit
        }
    ' "$file"
}

read_tcp_counter() {
    read_net_counter /proc/net/snmp Tcp "$1"
}

read_tcpext_counter() {
    read_net_counter /proc/net/netstat TcpExt "$1"
}

safe_counter() {
    local value=${1:-0}
    if [[ "$value" =~ ^[0-9]+$ ]]; then
        printf '%s' "$value"
    else
        printf '0'
    fi
}

counter_delta() {
    local before=$1
    local after=$2
    local delta=$((after - before))

    [ "$delta" -lt 0 ] && delta=0
    printf '%s' "$delta"
}

read_probe_counters() {
    local prefix=$1

    printf -v "${prefix}_OUT" '%s' "$(safe_counter "$(read_tcp_counter OutSegs)")"
    printf -v "${prefix}_RETR" '%s' "$(safe_counter "$(read_tcp_counter RetransSegs)")"
    printf -v "${prefix}_FAST_RETR" '%s' "$(safe_counter "$(read_tcpext_counter TCPFastRetrans)")"
    printf -v "${prefix}_SLOW_RETR" '%s' "$(safe_counter "$(read_tcpext_counter TCPSlowStartRetrans)")"
    printf -v "${prefix}_TIMEOUTS" '%s' "$(safe_counter "$(read_tcpext_counter TCPTimeouts)")"
    printf -v "${prefix}_LOSS_PROBES" '%s' "$(safe_counter "$(read_tcpext_counter TCPLossProbes)")"
    printf -v "${prefix}_DSACK_RECV" '%s' "$(safe_counter "$(read_tcpext_counter TCPDSACKRecv)")"
    printf -v "${prefix}_SACK_REORDER" '%s' "$(safe_counter "$(read_tcpext_counter TCPSACKReorder)")"
    printf -v "${prefix}_RENO_REORDER" '%s' "$(safe_counter "$(read_tcpext_counter TCPRenoReorder)")"
    printf -v "${prefix}_TS_REORDER" '%s' "$(safe_counter "$(read_tcpext_counter TCPTSReorder)")"
    printf -v "${prefix}_LOST_RETRANS" '%s' "$(safe_counter "$(read_tcpext_counter TCPLostRetransmit)")"
}

PROBE_BYTES=0
PROBE_SUCCEEDED=0

generate_retr_probe_traffic() {
    local probe_dir="$WORK_DIR/retr-probe"
    local timer_pid url result bytes http_code curl_rc index=0
    local pids=()

    mkdir -p "$probe_dir"
    sleep "$RETR_PROBE_SECONDS" &
    timer_pid=$!

    if command_exists curl && [ -n "$IPVER_FLAG" ]; then
        for url in "${SPEED_URLS[@]}"; do
            index=$((index + 1))
            (
                result=""
                curl_rc=0
                result=$(curl "$IPVER_FLAG" --fail --location --silent --show-error \
                    --output /dev/null --connect-timeout 2 --max-time "$RETR_PROBE_SECONDS" \
                    --write-out '%{size_download}|%{http_code}' "$url" 2>/dev/null) || curl_rc=$?
                printf '%s|%s\n' "$result" "$curl_rc" > "$probe_dir/$index.result"
            ) &
            pids+=("$!")
        done
    fi

    for probe_pid in "${pids[@]}"; do
        wait "$probe_pid" || true
    done
    wait "$timer_pid" || true

    for result_file in "$probe_dir"/*.result; do
        [ -f "$result_file" ] || continue
        IFS='|' read -r bytes http_code curl_rc < "$result_file" || true
        if [[ "${bytes:-}" =~ ^[0-9]+([.][0-9]+)?$ ]] &&
            [[ "${http_code:-}" =~ ^[23][0-9][0-9]$ ]] && float_gt "$bytes" 0; then
            bytes=$(awk -v value="$bytes" 'BEGIN { printf "%.0f", value }')
            PROBE_BYTES=$((PROBE_BYTES + bytes))
            PROBE_SUCCEEDED=$((PROBE_SUCCEEDED + 1))
        fi
    done
}

read_probe_counters BEFORE
generate_retr_probe_traffic
read_probe_counters AFTER

DELTA_OUT=$(counter_delta "$BEFORE_OUT" "$AFTER_OUT")
DELTA_RETR=$(counter_delta "$BEFORE_RETR" "$AFTER_RETR")
DELTA_FAST_RETR=$(counter_delta "$BEFORE_FAST_RETR" "$AFTER_FAST_RETR")
DELTA_SLOW_RETR=$(counter_delta "$BEFORE_SLOW_RETR" "$AFTER_SLOW_RETR")
DELTA_TIMEOUTS=$(counter_delta "$BEFORE_TIMEOUTS" "$AFTER_TIMEOUTS")
DELTA_LOSS_PROBES=$(counter_delta "$BEFORE_LOSS_PROBES" "$AFTER_LOSS_PROBES")
DELTA_DSACK_RECV=$(counter_delta "$BEFORE_DSACK_RECV" "$AFTER_DSACK_RECV")
DELTA_LOST_RETRANS=$(counter_delta "$BEFORE_LOST_RETRANS" "$AFTER_LOST_RETRANS")
DELTA_SACK_REORDER=$(counter_delta "$BEFORE_SACK_REORDER" "$AFTER_SACK_REORDER")
DELTA_RENO_REORDER=$(counter_delta "$BEFORE_RENO_REORDER" "$AFTER_RENO_REORDER")
DELTA_TS_REORDER=$(counter_delta "$BEFORE_TS_REORDER" "$AFTER_TS_REORDER")
DELTA_REORDER=$((DELTA_SACK_REORDER + DELTA_RENO_REORDER + DELTA_TS_REORDER))

RETR_VALID=0
RETR_RATE=""
RETR_PERCENT_DISPLAY="N/A"
RETR_CONFIDENCE="unavailable"
if [ "$DELTA_OUT" -gt 0 ]; then
    RETR_RATE=$(awk -v retrans="$DELTA_RETR" -v out="$DELTA_OUT" \
        'BEGIN { printf "%.3f", retrans * 100 / out }')
    RETR_PERCENT_DISPLAY="${RETR_RATE}%"
    RETR_VALID=1
    if [ "$DELTA_OUT" -ge "$RETR_CONFIDENCE_MIN_OUT" ]; then
        RETR_CONFIDENCE="normal"
    else
        RETR_CONFIDENCE="low"
    fi
fi

if [ "$RETR_VALID" -eq 1 ]; then
    log "Host TCP retransmission rate: ${RETR_RATE}% (+${DELTA_RETR}/+${DELTA_OUT}, confidence: $RETR_CONFIDENCE)"
else
    log "Host TCP retransmission rate: N/A (no outgoing TCP segments observed)"
fi
log "Retransmission probe: $(format_megabytes "$PROBE_BYTES") MiB downloaded by $PROBE_SUCCEEDED endpoint(s) in ${RETR_PROBE_SECONDS}s"
log "Retransmission detail: fast=+${DELTA_FAST_RETR}, slow=+${DELTA_SLOW_RETR}, timeout=+${DELTA_TIMEOUTS}, loss_probe=+${DELTA_LOSS_PROBES}, dsack=+${DELTA_DSACK_RECV}, reorder=+${DELTA_REORDER}, lost_retrans=+${DELTA_LOST_RETRANS}"

SCORE=100
QUALITY_LATENCY_VALID=0
QUALITY_LATENCY=""
if [ "$RTT_VALID" -eq 1 ]; then
    QUALITY_LATENCY=$RTT
    QUALITY_LATENCY_VALID=1
elif [ "$LATENCY_VALID" -eq 1 ]; then
    QUALITY_LATENCY=$LATENCY
    QUALITY_LATENCY_VALID=1
fi

if [ "$QUALITY_LATENCY_VALID" -eq 1 ]; then
    if float_gt "$QUALITY_LATENCY" 200; then
        SCORE=$((SCORE - 30))
    elif float_gt "$QUALITY_LATENCY" 100; then
        SCORE=$((SCORE - 15))
    fi
fi

if [ "$LOSS_VALID" -eq 1 ]; then
    if float_gt "$LOSS" 5; then
        SCORE=$((SCORE - 40))
    elif float_gt "$LOSS" 1; then
        SCORE=$((SCORE - 20))
    fi
fi

if [ "$JITTER_VALID" -eq 1 ] && float_gt "$JITTER" 25; then
    SCORE=$((SCORE - 15))
fi

if [ "$RETR_CONFIDENCE" = "normal" ]; then
    if float_gt "$RETR_RATE" 5; then
        SCORE=$((SCORE - 30))
    elif float_gt "$RETR_RATE" 2; then
        SCORE=$((SCORE - 15))
    fi
fi

[ "$SCORE" -lt 0 ] && SCORE=0

if [ "$SCORE" -ge 80 ] && [ "$QUALITY_LATENCY_VALID" -eq 1 ] &&
    [ "$LOSS_VALID" -eq 1 ] && [ "$RETR_CONFIDENCE" = "normal" ]; then
    MODE="aggressive"
elif [ "$SCORE" -ge 55 ]; then
    MODE="balanced"
else
    MODE="stable"
fi

case "$MODE" in
    aggressive)
        BDP_HEADROOM="3.0"
        TCP_REORDERING=3
        TCP_LIMIT_OUTPUT_BYTES=1048576
        ;;
    balanced)
        BDP_HEADROOM="2.5"
        TCP_REORDERING=7
        TCP_LIMIT_OUTPUT_BYTES=524288
        ;;
    stable)
        BDP_HEADROOM="2.0"
        TCP_REORDERING=7
        TCP_LIMIT_OUTPUT_BYTES=262144
        ;;
esac

RETR_PROFILE="normal"
REORDER_EVIDENCE=$((DELTA_REORDER + DELTA_DSACK_RECV))
if [ "$RETR_CONFIDENCE" = "normal" ] && float_gt "$RETR_RATE" 2 &&
    [ "$REORDER_EVIDENCE" -gt 0 ] && [ "$DELTA_TIMEOUTS" -eq 0 ] &&
    { [ "$LOSS_VALID" -eq 0 ] || ! float_gt "$LOSS" 1; }; then
    TCP_REORDERING=15
    if float_gt "$RETR_RATE" 5 || [ "$DELTA_REORDER" -gt 0 ]; then
        TCP_REORDERING=30
    fi
    RETR_PROFILE="reordering-sensitive"
elif { [ "$LOSS_VALID" -eq 1 ] && float_gt "$LOSS" 2; } ||
    { [ "$RETR_CONFIDENCE" = "normal" ] && float_gt "$RETR_RATE" 3 &&
        { [ "$DELTA_TIMEOUTS" -gt 0 ] || [ "$DELTA_LOST_RETRANS" -gt 0 ]; }; }; then
    BDP_HEADROOM="2.0"
    TCP_LIMIT_OUTPUT_BYTES=262144
    RETR_PROFILE="lossy"
fi

log "Score/mode/profile: $SCORE / $MODE / $RETR_PROFILE"

MIN_BUF=4194304
MAX_BUF=134217728
if [ -r /proc/meminfo ]; then
    MEM_TOTAL_KB=$(awk '/^MemTotal:/ { print $2; exit }' /proc/meminfo)
    if [[ "${MEM_TOTAL_KB:-}" =~ ^[0-9]+$ ]]; then
        MEMORY_BUF_CAP=$((MEM_TOTAL_KB * 1024 / 16))
        [ "$MEMORY_BUF_CAP" -lt 8388608 ] && MEMORY_BUF_CAP=8388608
        [ "$MEMORY_BUF_CAP" -lt "$MAX_BUF" ] && MAX_BUF=$MEMORY_BUF_CAP
    fi
fi

BUFFER_SOURCE="conservative fallback"
BDP_BYTES=16777216
if [ "$SPEED_VALID" -eq 1 ] && [ "$RTT_VALID" -eq 1 ]; then
    BDP_BYTES=$(awk -v mbps="$SPEED_MBPS" -v rtt="$RTT" -v headroom="$BDP_HEADROOM" 'BEGIN {
        value = mbps * 1000000 / 8 * rtt / 1000 * headroom
        printf "%.0f", value
    }')
    BUFFER_SOURCE="measured BDP"
fi
[ "$BDP_BYTES" -lt "$MIN_BUF" ] && BDP_BYTES=$MIN_BUF
[ "$BDP_BYTES" -gt "$MAX_BUF" ] && BDP_BYTES=$MAX_BUF

TCP_RMEM_DEFAULT=131072
TCP_WMEM_DEFAULT=65536
log "Socket buffer ceiling: $(format_megabytes "$BDP_BYTES") MiB ($BUFFER_SOURCE, headroom=${BDP_HEADROOM}x)"

TMP_CONF="$WORK_DIR/sysctl.conf"
SKIPPED_SYSCTLS=()

append_sysctl() {
    local key=$1
    local value=$2

    if sysctl_supported "$key"; then
        printf '%s = %s\n' "$key" "$value" >> "$TMP_CONF"
    else
        SKIPPED_SYSCTLS+=("$key")
    fi
}

cat > "$TMP_CONF" <<EOF
# BBR Adaptive ${VERSION}
# Generated: $(date '+%Y-%m-%d %H:%M:%S %z')
# Kernel: $KERNEL_RELEASE
# Mode/score/profile: $MODE / $SCORE / $RETR_PROFILE
# Measurements: bandwidth=$SPEED_DISPLAY, rtt=$RTT_DISPLAY, loss=$LOSS_DISPLAY, jitter=$JITTER_DISPLAY
# Host-wide retransmission: $RETR_PERCENT_DISPLAY (confidence=$RETR_CONFIDENCE, +$DELTA_RETR/+$DELTA_OUT)
# Buffer source: $BUFFER_SOURCE

# BBR and pacing. Existing connections retain their current congestion control.
EOF
append_sysctl net.core.default_qdisc "$QDISC"
append_sysctl net.ipv4.tcp_congestion_control bbr

cat >> "$TMP_CONF" <<EOF

# TCP autotuning ceilings. Defaults stay modest to avoid per-socket memory waste.
EOF
append_sysctl net.core.rmem_max "$BDP_BYTES"
append_sysctl net.core.wmem_max "$BDP_BYTES"
append_sysctl net.ipv4.tcp_rmem "4096 $TCP_RMEM_DEFAULT $BDP_BYTES"
append_sysctl net.ipv4.tcp_wmem "4096 $TCP_WMEM_DEFAULT $BDP_BYTES"
append_sysctl net.ipv4.tcp_moderate_rcvbuf 1

cat >> "$TMP_CONF" <<EOF

# Loss recovery and path compatibility.
EOF
append_sysctl net.ipv4.tcp_sack 1
append_sysctl net.ipv4.tcp_dsack 1
append_sysctl net.ipv4.tcp_recovery 1
append_sysctl net.ipv4.tcp_early_retrans 3
append_sysctl net.ipv4.tcp_reordering "$TCP_REORDERING"
append_sysctl net.ipv4.tcp_max_reordering 300
append_sysctl net.ipv4.tcp_mtu_probing 1
append_sysctl net.ipv4.tcp_ecn "$ENABLE_ECN"
append_sysctl net.ipv4.tcp_ecn_fallback 1

cat >> "$TMP_CONF" <<EOF

# Queue limits for server and proxy workloads.
EOF
append_sysctl net.ipv4.tcp_limit_output_bytes "$TCP_LIMIT_OUTPUT_BYTES"
append_sysctl net.core.somaxconn "$MODE_SOMAXCONN"
append_sysctl net.core.netdev_max_backlog "$MODE_BACKLOG"
append_sysctl net.ipv4.tcp_max_syn_backlog "$MODE_SYN_BACKLOG"

if [ "$ENABLE_IP_FORWARD_IS_SET" -eq 1 ]; then
    cat >> "$TMP_CONF" <<EOF

# Explicitly requested by ENABLE_IP_FORWARD. It is never changed implicitly.
EOF
    append_sysctl net.ipv4.ip_forward "$ENABLE_IP_FORWARD_VALUE"
fi

if [ "${#SKIPPED_SYSCTLS[@]}" -gt 0 ]; then
    warn "unsupported sysctl keys omitted: ${SKIPPED_SYSCTLS[*]}"
fi

RUNTIME_ROLLBACK="$WORK_DIR/runtime-rollback.conf"
: > "$RUNTIME_ROLLBACK"
while IFS= read -r config_line; do
    case "$config_line" in
        ''|'#'*) continue ;;
    esac
    key=${config_line%%=*}
    key=${key//[[:space:]]/}
    old_value=$(sysctl -n "$key" 2>/dev/null || true)
    if [ -n "$old_value" ]; then
        printf '%s = %s\n' "$key" "$old_value" >> "$RUNTIME_ROLLBACK"
    fi
done < "$TMP_CONF"

atomic_install() {
    local source=$1
    local destination=$2
    local mode=${3:-0644}

    EXTERNAL_TMP=$(mktemp "${destination}.tmp.XXXXXX") || return 1
    if ! install -m "$mode" "$source" "$EXTERNAL_TMP"; then
        rm -f "$EXTERNAL_TMP"
        EXTERNAL_TMP=""
        return 1
    fi
    if ! mv -f "$EXTERNAL_TMP" "$destination"; then
        rm -f "$EXTERNAL_TMP"
        EXTERNAL_TMP=""
        return 1
    fi
    EXTERNAL_TMP=""
}

PREVIOUS_CONF="$WORK_DIR/previous.conf"
HAD_PREVIOUS_CONF=0
if [ -f "$OUR_CONF" ]; then
    cp -p "$OUR_CONF" "$PREVIOUS_CONF"
    HAD_PREVIOUS_CONF=1
fi

PREVIOUS_MODULE_CONF="$WORK_DIR/previous-module.conf"
HAD_PREVIOUS_MODULE_CONF=0
TOUCHED_MODULE_CONF=0
if [ -f "$MODULE_CONF" ]; then
    cp -p "$MODULE_CONF" "$PREVIOUS_MODULE_CONF"
    HAD_PREVIOUS_MODULE_CONF=1
fi

DISABLED_LEGACY=()
LEGACY_CONFS=(
    "/etc/sysctl.d/99-bbr-global.conf"
    "/etc/sysctl.d/99-bbr-v3.5.conf"
    "/etc/sysctl.d/99-bbr-v3.conf"
    "/etc/sysctl.d/20-mode.conf"
)

restore_disabled_legacy() {
    local pair original backup

    for pair in "${DISABLED_LEGACY[@]}"; do
        IFS='|' read -r original backup <<< "$pair"
        if [ -f "$backup" ]; then
            mv "$backup" "$original" || warn "could not restore legacy config: $original"
        fi
    done
}

RUN_STAMP=$(date '+%Y%m%d%H%M%S')
for legacy_file in "${LEGACY_CONFS[@]}"; do
    if [ -f "$legacy_file" ]; then
        legacy_backup="${legacy_file}.disabled-${RUN_STAMP}"
        if ! mv "$legacy_file" "$legacy_backup"; then
            restore_disabled_legacy
            die "cannot disable conflicting legacy config: $legacy_file"
        fi
        DISABLED_LEGACY+=("$legacy_file|$legacy_backup")
        log "Disabled legacy config: $legacy_file"
    fi
done

rollback_changes() {
    warn "rolling back persistent and runtime sysctl changes"
    if [ "$HAD_PREVIOUS_CONF" -eq 1 ]; then
        atomic_install "$PREVIOUS_CONF" "$OUR_CONF" 0644 || warn "could not restore previous $OUR_CONF"
    else
        rm -f "$OUR_CONF"
    fi
    if [ "$TOUCHED_MODULE_CONF" -eq 1 ]; then
        if [ "$HAD_PREVIOUS_MODULE_CONF" -eq 1 ]; then
            atomic_install "$PREVIOUS_MODULE_CONF" "$MODULE_CONF" 0644 || \
                warn "could not restore previous $MODULE_CONF"
        else
            rm -f "$MODULE_CONF"
        fi
    fi
    if [ -s "$RUNTIME_ROLLBACK" ]; then
        sysctl -p "$RUNTIME_ROLLBACK" >/dev/null 2>&1 || warn "some runtime sysctls could not be restored"
    fi
    restore_disabled_legacy
}

atomic_install "$TMP_CONF" "$OUR_CONF" 0644 || {
    rollback_changes
    die "cannot install $OUR_CONF"
}

if command_exists modprobe; then
    atomic_install "$WORK_DIR/module.conf" "$MODULE_CONF" 0644 || {
        rollback_changes
        die "cannot install $MODULE_CONF"
    }
    TOUCHED_MODULE_CONF=1
fi

if ! sysctl -p "$OUR_CONF"; then
    rollback_changes
    die "the generated sysctl configuration was rejected; previous settings were restored"
fi

SYSTEM_APPLY_OK=1
if ! sysctl --system; then
    SYSTEM_APPLY_OK=0
    warn "sysctl --system reported an error; required BBR values will still be verified"
fi

CUR_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)
CUR_QDISC=$(sysctl -n net.core.default_qdisc 2>/dev/null || true)
if [ "$CUR_CC" != "bbr" ] || [ "$CUR_QDISC" != "$QDISC" ]; then
    warn "a later sysctl configuration overrode this script (cc=${CUR_CC:-unknown}, qdisc=${CUR_QDISC:-unknown})"
    grep -R -l -E '^[[:space:]]*net\.(ipv4\.tcp_congestion_control|core\.default_qdisc)[[:space:]]*=' \
        /etc/sysctl.conf /etc/sysctl.d /usr/lib/sysctl.d /lib/sysctl.d 2>/dev/null || true
    rollback_changes
    die "BBR persistence verification failed; resolve the conflicting config and rerun"
fi

route_interfaces() {
    command_exists ip || return 0
    {
        ip -o -4 route show default 2>/dev/null || true
        ip -o -6 route show default 2>/dev/null || true
    } | awk '
        {
            for (i = 1; i <= NF; i++) {
                if ($i == "dev" && (i + 1) <= NF && !seen[$(i + 1)]++) print $(i + 1)
            }
        }
    '
}

mapfile -t ROUTE_INTERFACES < <(route_interfaces)
LIVE_QDISC_ERRORS=0
if [ "$APPLY_QDISC_NOW" -eq 1 ]; then
    if ! command_exists tc; then
        warn "APPLY_QDISC_NOW=1 was requested but tc is unavailable"
        LIVE_QDISC_ERRORS=1
    else
        for interface in "${ROUTE_INTERFACES[@]}"; do
            [ -n "$interface" ] || continue
            root_qdisc=$(tc qdisc show dev "$interface" 2>/dev/null | \
                awk '$0 ~ / root / { print $2; exit }') || root_qdisc=""
            if [ -z "$root_qdisc" ]; then
                warn "could not inspect the live qdisc on $interface"
                LIVE_QDISC_ERRORS=1
                continue
            fi
            if [ "$root_qdisc" = "mq" ]; then
                warn "live qdisc on $interface is mq; preserving its multiqueue hierarchy"
                LIVE_QDISC_ERRORS=1
                continue
            fi
            if ! tc qdisc replace dev "$interface" root "$QDISC"; then
                warn "could not replace live qdisc on $interface"
                LIVE_QDISC_ERRORS=1
            fi
        done
    fi
fi

ACTIVE_QDISCS=""
if command_exists tc && [ "${#ROUTE_INTERFACES[@]}" -gt 0 ]; then
    for interface in "${ROUTE_INTERFACES[@]}"; do
        [ -n "$interface" ] || continue
        interface_qdiscs=$(tc qdisc show dev "$interface" 2>/dev/null | \
            awk '{ if (!seen[$2]++) out = out (out ? "," : "") $2 } END { print out }') || \
            interface_qdiscs=""
        [ -z "$interface_qdiscs" ] && interface_qdiscs="unknown"
        if [ -n "$ACTIVE_QDISCS" ]; then
            ACTIVE_QDISCS="$ACTIVE_QDISCS; "
        fi
        ACTIVE_QDISCS="${ACTIVE_QDISCS}${interface}:${interface_qdiscs}"
    done
fi
[ -z "$ACTIVE_QDISCS" ] && ACTIVE_QDISCS="unavailable"

RETR_DISPLAY="N/A"
[ "$RETR_VALID" -eq 1 ] && RETR_DISPLAY="${RETR_RATE}% ($RETR_CONFIDENCE)"

echo "=================================="
if [ "$WARNINGS" -gt 0 ] || [ "$SYSTEM_APPLY_OK" -eq 0 ] || [ "$LIVE_QDISC_ERRORS" -gt 0 ]; then
    echo " SUCCESS WITH WARNINGS"
else
    echo " SUCCESS"
fi
echo " KERNEL:        $KERNEL_RELEASE"
echo " CPU:           $CPU_LEVEL ($CPU_CORE cores)"
echo " NETWORK:       $NETWORK_FAMILY"
echo " BANDWIDTH:     $SPEED_DISPLAY ($BANDWIDTH)"
echo " TCP LATENCY:   $LATENCY_DISPLAY"
echo " ICMP RTT:      $RTT_DISPLAY"
echo " LOSS:          $LOSS_DISPLAY"
echo " JITTER:        $JITTER_DISPLAY"
echo " RETRANSMIT:    $RETR_DISPLAY"
echo " RETR TRAFFIC:  $(format_megabytes "$PROBE_BYTES") MiB / $PROBE_SUCCEEDED endpoints"
echo " PROFILE:       $RETR_PROFILE"
echo " MODE / SCORE:  $MODE / $SCORE"
echo " BUFFER MAX:    $(format_megabytes "$BDP_BYTES") MiB ($BUFFER_SOURCE)"
echo " REORDERING:    $TCP_REORDERING"
echo " CONGESTION:    $CUR_CC"
echo " DEFAULT QDISC: $CUR_QDISC"
echo " ACTIVE QDISC:  $ACTIVE_QDISCS"
echo " CONFIG:        $OUR_CONF"
echo "=================================="
echo "OK: BBR is active for new TCP connections and is configured persistently."

if [ "$ACTIVE_QDISCS" != "unavailable" ] && ! printf '%s\n' "$ACTIVE_QDISCS" | grep -qw "$QDISC"; then
    echo "NOTE: existing interfaces still use their current qdisc. The default applies when a qdisc is recreated or after reboot."
    echo "      To replace simple live root qdiscs immediately, rerun with APPLY_QDISC_NOW=1."
fi
echo "NOTE: retransmission counters are real, host-wide kernel deltas; they are not per-curl counters."
echo "      Existing TCP connections keep their previous congestion-control algorithm until reconnected."
