#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'
export LC_ALL=C
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

VERSION="2.1.0"
TARGET_CONF="/etc/sysctl.d/99-zz-bbr.conf"
MODULE_CONF="/etc/modules-load.d/99-zz-bbr.conf"
STATE_DIR="/var/lib/bbr-clean-install"
LOCK_FILE="/run/lock/bbr-clean-install.lock"
MARKER="# Managed by bbr-clean-install"
BBR_REGEX='^[[:space:]]*(net\.core\.default_qdisc|net\.ipv4\.tcp_congestion_control)[[:space:]]*='
LEGACY_ADAPTIVE_REGEX='^[[:space:]]*(net\.core\.(rmem_max|wmem_max|somaxconn|netdev_max_backlog)|net\.ipv4\.(tcp_rmem|tcp_wmem|tcp_moderate_rcvbuf|tcp_sack|tcp_dsack|tcp_recovery|tcp_early_retrans|tcp_reordering|tcp_max_reordering|tcp_mtu_probing|tcp_ecn|tcp_ecn_fallback|tcp_limit_output_bytes|tcp_max_syn_backlog))[[:space:]]*='
OTHER_TUNING_REGEX='^[[:space:]]*(fs\.file-max|net\.ipv4\.(tcp_fastopen|tcp_slow_start_after_idle|tcp_window_scaling|tcp_max_tw_buckets|tcp_tw_reuse|tcp_fin_timeout|ip_forward|ip_local_port_range)|net\.ipv6\.conf\.all\.forwarding|net\.netfilter\.(nf_conntrack_max|nf_conntrack_tcp_timeout_established|nf_conntrack_tcp_timeout_time_wait|nf_conntrack_tcp_timeout_close_wait)|vm\.(swappiness|vfs_cache_pressure|min_free_kbytes))[[:space:]]*='
MODULE_REGEX='^[[:space:]]*(tcp_bbr|sch_fq)([[:space:]]*(#.*)?)?$'

ACTION="install"
OPTIMIZE=0
BANDWIDTH_MBPS=""
RTT_MS=""
BDP_HEADROOM="2.0"
BUFFER_CAP_MB=128
WORK_DIR=""
STATE_STAGING=""
BACKUP_INDEX=0
FULL_REMOVE=()
REWRITE_FILES=()
INSTALL_KEYS=()
INSTALL_VALUES=()
CLEAN_KEYS=()
CLEAN_REGEX="$BBR_REGEX"

LEGACY_ADAPTIVE_KEYS=(
    net.core.rmem_max
    net.core.wmem_max
    net.core.somaxconn
    net.core.netdev_max_backlog
    net.ipv4.tcp_rmem
    net.ipv4.tcp_wmem
    net.ipv4.tcp_moderate_rcvbuf
    net.ipv4.tcp_sack
    net.ipv4.tcp_dsack
    net.ipv4.tcp_recovery
    net.ipv4.tcp_early_retrans
    net.ipv4.tcp_reordering
    net.ipv4.tcp_max_reordering
    net.ipv4.tcp_mtu_probing
    net.ipv4.tcp_ecn
    net.ipv4.tcp_ecn_fallback
    net.ipv4.tcp_limit_output_bytes
    net.ipv4.tcp_max_syn_backlog
)

LEGACY_SYSCTL_FILES=(
    "/etc/sysctl.d/99-zz-bbr-adaptive.conf"
    "/etc/sysctl.d/99-bbr-adaptive-safe.conf"
    "/etc/sysctl.d/99-bbr-global.conf"
    "/etc/sysctl.d/99-bbr-v3.5.conf"
    "/etc/sysctl.d/99-bbr-v3.conf"
    "/etc/sysctl.d/20-mode.conf"
    "/etc/sysctl.d/20-bandwidth.conf"
    "/etc/sysctl.d/30-cpu.conf"
    "/etc/sysctl.d/99-bbr.conf"
)

LEGACY_MODULE_FILES=(
    "/etc/modules-load.d/99-bbr-adaptive.conf"
    "/etc/modules-load.d/99-bbr-adaptive-safe.conf"
)

log() {
    printf '%s\n' "$*"
}

warn() {
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
    case "${STATE_STAGING:-}" in
        /var/lib/bbr-clean-install.pending.*)
            [ ! -d "$STATE_STAGING" ] || rm -rf -- "$STATE_STAGING"
            ;;
    esac
    case "${WORK_DIR:-}" in
        /tmp/bbr-clean-install.*)
            [ ! -d "$WORK_DIR" ] || rm -rf -- "$WORK_DIR"
            ;;
    esac
}

trap cleanup EXIT

usage() {
    cat <<'EOF'
Usage:
  sudo bash bbr-clean-install.sh              Install clean BBR configuration.
  sudo bash bbr-clean-install.sh --optimize 1000 50
                                               Install with safe 1000 Mbps/50 ms BDP tuning.
  bash bbr-clean-install.sh --status          Show effective values and definitions.
  sudo bash bbr-clean-install.sh --uninstall  Restore the pre-install state.

The installer keeps Debian's vendor defaults, disables known old BBR optimizer
files, removes duplicate managed assignments from local configuration files,
and creates one authoritative configuration. Optimization never runs a public
speed test: bandwidth and RTT must be supplied explicitly.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --status)
            [ "$ACTION" = "install" ] || die "choose only one action"
            ACTION="status"
            ;;
        --uninstall)
            [ "$ACTION" = "install" ] || die "choose only one action"
            ACTION="uninstall"
            ;;
        --optimize)
            [ "$ACTION" = "install" ] || die "--optimize cannot be combined with $ACTION"
            [ "$OPTIMIZE" -eq 0 ] || die "--optimize may only be specified once"
            [ "$#" -ge 3 ] || die "--optimize requires bandwidth Mbps and RTT ms"
            OPTIMIZE=1
            BANDWIDTH_MBPS=$2
            RTT_MS=$3
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            die "unknown option: $1"
            ;;
    esac
    shift
done

if [ "$ACTION" != "install" ] && [ "$OPTIMIZE" -eq 1 ]; then
    die "--optimize is only valid during installation"
fi

if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    die "Bash 4 or newer is required"
fi
if [ "$(uname -s)" != "Linux" ]; then
    die "this script only supports Linux"
fi

for tool in awk grep sysctl mktemp install mv cp rm mkdir chmod cat uname id date; do
    command_exists "$tool" || die "missing required command: $tool"
done

is_positive_number() {
    [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]] &&
        awk -v value="$1" 'BEGIN { exit !(value > 0) }'
}

if [ "$OPTIMIZE" -eq 1 ]; then
    is_positive_number "$BANDWIDTH_MBPS" ||
        die "optimization bandwidth must be a positive number"
    is_positive_number "$RTT_MS" ||
        die "optimization RTT must be a positive number"
    awk -v value="$BANDWIDTH_MBPS" 'BEGIN { exit !(value >= 1 && value <= 1000000) }' ||
        die "optimization bandwidth must be between 1 and 1000000 Mbps"
    awk -v value="$RTT_MS" 'BEGIN { exit !(value >= 0.1 && value <= 60000) }' ||
        die "optimization RTT must be between 0.1 and 60000 ms"
fi

read_sysctl() {
    sysctl -n "$1" 2>/dev/null
}

normalize_ws() {
    awk '{$1=$1; print}'
}

owned_file() {
    local file=$1
    [ -f "$file" ] && grep -Fq "$MARKER" "$file"
}

acquire_lock() {
    mkdir -p /run/lock
    if command_exists flock; then
        exec 9>"$LOCK_FILE"
        flock -n 9 || die "another bbr-clean-install process is running"
    else
        warn "flock is unavailable; concurrent runs cannot be prevented"
    fi
}

atomic_install() {
    local source=$1 destination=$2 mode=${3:-0644} temporary
    temporary=$(mktemp "${destination}.tmp.XXXXXX") || return 1
    if ! install -m "$mode" "$source" "$temporary"; then
        rm -f -- "$temporary"
        return 1
    fi
    if ! mv -f -- "$temporary" "$destination"; then
        rm -f -- "$temporary"
        return 1
    fi
}

atomic_restore() {
    local source=$1 destination=$2 temporary
    temporary=$(mktemp "${destination}.tmp.XXXXXX") || return 1
    if ! cp -p -- "$source" "$temporary"; then
        rm -f -- "$temporary"
        return 1
    fi
    if ! mv -f -- "$temporary" "$destination"; then
        rm -f -- "$temporary"
        return 1
    fi
}

atomic_rewrite() {
    local content=$1 destination=$2 temporary
    temporary=$(mktemp "${destination}.tmp.XXXXXX") || return 1
    if ! cp -p -- "$destination" "$temporary"; then
        rm -f -- "$temporary"
        return 1
    fi
    if ! cat "$content" > "$temporary"; then
        rm -f -- "$temporary"
        return 1
    fi
    if ! mv -f -- "$temporary" "$destination"; then
        rm -f -- "$temporary"
        return 1
    fi
}

show_definitions() {
    local path existing
    local shown=()
    for path in \
        /usr/lib/sysctl.d/*.conf \
        /lib/sysctl.d/*.conf \
        /run/sysctl.d/*.conf \
        /etc/sysctl.d/*.conf \
        /etc/sysctl.conf; do
        [ -f "$path" ] || continue
        for existing in "${shown[@]}"; do
            [ "$path" -ef "$existing" ] && continue 2
        done
        if grep -Eq -- "$BBR_REGEX" "$path"; then
            shown+=("$path")
            printf '  %s\n' "$path"
            grep -En -- "$BBR_REGEX" "$path" | awk '{print "    " $0}'
        fi
    done
}

print_local_matches() {
    local regex=$1 exclude_target=${2:-0}
    local path
    MATCH_COUNT=0
    for path in /etc/sysctl.conf /etc/sysctl.d/*.conf; do
        [ -f "$path" ] || continue
        if [ "$path" != "/etc/sysctl.conf" ] && [ -e /etc/sysctl.conf ] &&
            [ "$path" -ef /etc/sysctl.conf ]; then
            continue
        fi
        if [ "$exclude_target" -eq 1 ] && [ "$path" = "$TARGET_CONF" ]; then
            continue
        fi
        if grep -Eq -- "$regex" "$path"; then
            MATCH_COUNT=$((MATCH_COUNT + 1))
            printf '  %s\n' "$path"
            grep -En -- "$regex" "$path" | awk '{print "    " $0}'
        fi
    done
}

show_module_definitions() {
    local path
    MODULE_MATCH_COUNT=0
    MODULE_OUTSIDE_COUNT=0
    MODULE_TARGET_FOUND=0
    for path in /etc/modules-load.d/*.conf; do
        [ -f "$path" ] || continue
        if grep -Eq -- "$MODULE_REGEX" "$path"; then
            MODULE_MATCH_COUNT=$((MODULE_MATCH_COUNT + 1))
            if [ "$path" = "$MODULE_CONF" ]; then
                MODULE_TARGET_FOUND=1
            else
                MODULE_OUTSIDE_COUNT=$((MODULE_OUTSIDE_COUNT + 1))
            fi
            printf '  %s\n' "$path"
            grep -En -- "$MODULE_REGEX" "$path" | awk '{print "    " $0}'
        fi
    done
}

show_backup_manifest() {
    local backup_name destination
    if [ -f "$STATE_DIR/manifest.tsv" ]; then
        while IFS=$'\t' read -r backup_name destination; do
            [ -n "$destination" ] || continue
            printf '  %s\n' "$destination"
        done < "$STATE_DIR/manifest.tsv"
    fi
}

verify_target_runtime() {
    local config_line key expected actual
    TARGET_RUNTIME_ERRORS=0
    while IFS= read -r config_line; do
        case "$config_line" in
            ''|'#'*) continue ;;
        esac
        key=${config_line%%=*}
        key=${key//[[:space:]]/}
        expected=${config_line#*=}
        expected=$(printf '%s\n' "$expected" | normalize_ws)
        actual=$(read_sysctl "$key" || true)
        actual=$(printf '%s\n' "$actual" | normalize_ws)
        if [ "$actual" != "$expected" ]; then
            printf '  MISMATCH: %s (configured: %s, runtime: %s)\n' \
                "$key" "$expected" "${actual:-unavailable}"
            TARGET_RUNTIME_ERRORS=$((TARGET_RUNTIME_ERRORS + 1))
        fi
    done < "$TARGET_CONF"
}

show_status() {
    local available current_cc current_qdisc state path profile
    local legacy_files=0 bbr_cleanup_issues=0 retained_tuning=0 target_ok=1
    available=$(read_sysctl net.ipv4.tcp_available_congestion_control || true)
    current_cc=$(read_sysctl net.ipv4.tcp_congestion_control || true)
    current_qdisc=$(read_sysctl net.core.default_qdisc || true)
    state="not installed by this script"
    [ ! -f "$STATE_DIR/installed" ] || state="installed"
    [ ! -f "$STATE_DIR/pending" ] || state="pending recovery"
    profile=$(awk -F= '$1 == "profile" {print $2; exit}' "$STATE_DIR/metadata" 2>/dev/null || true)
    [ -n "$profile" ] || profile="minimal or legacy state"

    log "BBR clean install $VERSION"
    log "Kernel:          $(uname -r)"
    log "Available CC:    ${available:-unavailable}"
    log "Effective CC:    ${current_cc:-unavailable}"
    log "Effective qdisc: ${current_qdisc:-unavailable}"
    log "State:           $state"
    log "Profile:         $profile"
    if [ "$state" != "installed" ]; then
        bbr_cleanup_issues=1
    fi

    if ! owned_file "$TARGET_CONF" ||
        ! grep -Eq '^[[:space:]]*net\.core\.default_qdisc[[:space:]]*=[[:space:]]*fq[[:space:]]*$' "$TARGET_CONF" ||
        ! grep -Eq '^[[:space:]]*net\.ipv4\.tcp_congestion_control[[:space:]]*=[[:space:]]*bbr[[:space:]]*$' "$TARGET_CONF"; then
        target_ok=0
        bbr_cleanup_issues=1
    fi
    if [ "$current_cc" != "bbr" ] || [ "$current_qdisc" != "fq" ]; then
        bbr_cleanup_issues=1
    fi

    log "Authoritative config integrity:"
    if [ "$target_ok" -eq 1 ]; then
        log "  OK: $TARGET_CONF"
        grep -En '^[[:space:]]*[A-Za-z0-9_.]+[[:space:]]*=' "$TARGET_CONF" |
            awk '{print "    " $0}'
        verify_target_runtime
        if [ "$TARGET_RUNTIME_ERRORS" -eq 0 ]; then
            log "  Runtime verification: OK (all managed settings match)"
        else
            bbr_cleanup_issues=1
        fi
    else
        log "  INVALID OR MISSING: $TARGET_CONF"
    fi
    log "Definitions found for these two keys:"
    show_definitions
    log "Only the last assignment for each key is effective."

    log "Known old optimizer files still active:"
    for path in "${LEGACY_SYSCTL_FILES[@]}" "${LEGACY_MODULE_FILES[@]}"; do
        if [ -e "$path" ]; then
            printf '  %s\n' "$path"
            legacy_files=$((legacy_files + 1))
        fi
    done
    if [ "$legacy_files" -eq 0 ]; then
        log "  none"
    else
        bbr_cleanup_issues=1
    fi

    log "Duplicate local BBR/qdisc definitions outside $TARGET_CONF:"
    print_local_matches "$BBR_REGEX" 1
    if [ "$MATCH_COUNT" -eq 0 ]; then
        log "  none"
    else
        bbr_cleanup_issues=1
    fi

    log "Legacy adaptive tuning keys still defined locally:"
    print_local_matches "$LEGACY_ADAPTIVE_REGEX" 1
    if [ "$MATCH_COUNT" -eq 0 ]; then
        log "  none"
    else
        bbr_cleanup_issues=1
    fi

    log "Other custom tuning retained for manual review:"
    print_local_matches "$OTHER_TUNING_REGEX" 1
    if [ "$MATCH_COUNT" -eq 0 ]; then
        log "  none"
    else
        retained_tuning=1
    fi

    log "BBR/qdisc module-load definitions:"
    show_module_definitions
    if [ "$MODULE_MATCH_COUNT" -eq 0 ]; then
        log "  none"
        bbr_cleanup_issues=1
    elif [ "$MODULE_TARGET_FOUND" -ne 1 ] || [ "$MODULE_OUTSIDE_COUNT" -gt 0 ] ||
        ! owned_file "$MODULE_CONF" ||
        ! grep -Eq '^[[:space:]]*tcp_bbr([[:space:]]*(#.*)?)?$' "$MODULE_CONF" ||
        ! grep -Eq '^[[:space:]]*sch_fq([[:space:]]*(#.*)?)?$' "$MODULE_CONF"; then
        bbr_cleanup_issues=1
    fi

    log "Original files preserved in recovery state:"
    show_backup_manifest
    if [ ! -s "$STATE_DIR/manifest.tsv" ]; then
        log "  none"
    fi

    if [ "$bbr_cleanup_issues" -eq 0 ]; then
        log "BBR cleanup audit: CLEAN"
    else
        log "BBR cleanup audit: REVIEW REQUIRED"
    fi
    if [ "$retained_tuning" -eq 1 ]; then
        log "Other tuning audit: PRESENT (not automatically removed)"
    else
        log "Other tuning audit: NONE"
    fi
    return "$bbr_cleanup_issues"
}

if [ "$ACTION" = "status" ]; then
    if show_status; then
        exit 0
    else
        exit 1
    fi
fi

[ "$(id -u)" -eq 0 ] || die "$ACTION must run as root"
acquire_lock

restore_state() {
    local errors=0 backup_name destination config_line key expected actual

    [ -f "$STATE_DIR/manifest.tsv" ] || {
        warn "backup manifest is missing"
        return 1
    }

    while IFS=$'\t' read -r backup_name destination; do
        [ -n "$backup_name" ] && [ -n "$destination" ] || continue
        if ! atomic_restore "$STATE_DIR/files/$backup_name" "$destination"; then
            warn "could not restore $destination"
            errors=1
        fi
    done < "$STATE_DIR/manifest.tsv"

    if [ -f "$STATE_DIR/absent.list" ]; then
        while IFS= read -r destination; do
            [ -n "$destination" ] || continue
            if [ -e "$destination" ]; then
                if owned_file "$destination"; then
                    rm -f -- "$destination" || errors=1
                else
                    warn "refusing to remove a file no longer owned by this script: $destination"
                    errors=1
                fi
            fi
        done < "$STATE_DIR/absent.list"
    fi

    if [ -s "$STATE_DIR/runtime.before.conf" ]; then
        sysctl -p "$STATE_DIR/runtime.before.conf" >/dev/null 2>&1 || errors=1
        while IFS= read -r config_line; do
            case "$config_line" in
                ''|'#'*) continue ;;
            esac
            key=${config_line%%=*}
            key=${key//[[:space:]]/}
            expected=${config_line#*=}
            expected=$(printf '%s\n' "$expected" | normalize_ws)
            actual=$(read_sysctl "$key" || true)
            actual=$(printf '%s\n' "$actual" | normalize_ws)
            if [ "$actual" != "$expected" ]; then
                warn "runtime restore verification failed for $key"
                errors=1
            fi
        done < "$STATE_DIR/runtime.before.conf"
    else
        warn "runtime backup is missing"
        errors=1
    fi

    return "$errors"
}

archive_state() {
    local archive
    archive="/root/bbr-clean-install-restored-$(date '+%Y%m%d%H%M%S')-$$"
    if mv -- "$STATE_DIR" "$archive"; then
        chmod 0700 "$archive"
        log "Backup archive: $archive"
    else
        warn "state was restored but could not be archived: $STATE_DIR"
    fi
}

if [ "$ACTION" = "uninstall" ]; then
    if [ ! -f "$STATE_DIR/installed" ] && [ ! -f "$STATE_DIR/pending" ]; then
        die "no recoverable installation state exists in $STATE_DIR"
    fi
    log "Restoring the state captured before installation..."
    if ! restore_state; then
        die "restore was incomplete; backup state remains in $STATE_DIR"
    fi
    archive_state
    log "Restore complete. Old files and runtime BBR/qdisc values are back."
    exit 0
fi

if [ -f "$STATE_DIR/installed" ]; then
    if [ "$OPTIMIZE" -eq 1 ]; then
        die "already installed; switch profiles with --uninstall, then rerun --optimize"
    fi
    log "BBR clean install is already present; validating the existing installation."
    if show_status; then
        log "Existing installation is healthy; no changes were needed."
        exit 0
    else
        die "existing installation requires review; no files were changed"
    fi
elif [ -f "$STATE_DIR/pending" ]; then
    die "a previous operation is pending; run --uninstall to recover it"
elif [ -e "$STATE_DIR" ]; then
    die "unknown installation state exists in $STATE_DIR; no files were changed"
fi
[ ! -L "$TARGET_CONF" ] || die "refusing to replace symlink: $TARGET_CONF"
[ ! -L "$MODULE_CONF" ] || die "refusing to replace symlink: $MODULE_CONF"

WORK_DIR=$(mktemp -d /tmp/bbr-clean-install.XXXXXX) ||
    die "could not create temporary directory"
TMP_CONF="$WORK_DIR/99-zz-bbr.conf"
TMP_MODULE="$WORK_DIR/modules.conf"

kernel_release=$(uname -r)
if [[ ! "$kernel_release" =~ ^([0-9]+)\.([0-9]+) ]]; then
    die "cannot parse kernel release: $kernel_release"
fi
kernel_major=${BASH_REMATCH[1]}
kernel_minor=${BASH_REMATCH[2]}
if [ "$kernel_major" -lt 4 ] || {
    [ "$kernel_major" -eq 4 ] && [ "$kernel_minor" -lt 9 ];
}; then
    die "kernel $kernel_release is too old for upstream BBR"
fi

if command_exists modprobe; then
    modprobe tcp_bbr 2>/dev/null || true
    modprobe sch_fq 2>/dev/null || die "the kernel cannot load sch_fq"
else
    warn "modprobe is unavailable; module availability cannot be preloaded"
fi
available_cc=$(read_sysctl net.ipv4.tcp_available_congestion_control || true)
printf '%s\n' "$available_cc" | grep -qw bbr ||
    die "the kernel does not expose BBR (available: ${available_cc:-none})"

sysctl_supported() {
    local key=$1
    [ -e "/proc/sys/${key//./\/}" ]
}

add_install_setting() {
    local key=$1 value=$2
    sysctl_supported "$key" || die "required sysctl is unavailable: $key"
    INSTALL_KEYS+=("$key")
    INSTALL_VALUES+=("$value")
}

is_uint() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

uint_or_zero() {
    local value=${1:-0}
    if is_uint "$value"; then
        printf '%s' "$value"
    else
        printf '0'
    fi
}

max_uint() {
    local maximum=0 value
    for value in "$@"; do
        value=$(uint_or_zero "$value")
        [ "$value" -le "$maximum" ] || maximum=$value
    done
    printf '%s' "$maximum"
}

add_optimized_settings() {
    local requested target cap memory_cap mem_total_kb
    local core_rmem core_wmem tcp_rmem tcp_wmem
    local rmin rdefault rmax wmin wdefault wmax

    requested=$(awk -v mbps="$BANDWIDTH_MBPS" -v rtt="$RTT_MS" -v headroom="$BDP_HEADROOM" \
        'BEGIN { printf "%.0f", mbps * 1000000 / 8 * rtt / 1000 * headroom }')
    target=$requested
    [ "$target" -ge 4194304 ] || target=4194304
    cap=$((BUFFER_CAP_MB * 1048576))

    if [ -r /proc/meminfo ]; then
        mem_total_kb=$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo)
        if is_uint "${mem_total_kb:-}"; then
            memory_cap=$((mem_total_kb * 1024 / 16))
            [ "$memory_cap" -ge 4194304 ] || memory_cap=4194304
            [ "$memory_cap" -ge "$cap" ] || cap=$memory_cap
        fi
    fi
    [ "$target" -le "$cap" ] || target=$cap

    core_rmem=$(uint_or_zero "$(read_sysctl net.core.rmem_max || true)")
    core_wmem=$(uint_or_zero "$(read_sysctl net.core.wmem_max || true)")
    tcp_rmem=$(read_sysctl net.ipv4.tcp_rmem || true)
    tcp_wmem=$(read_sysctl net.ipv4.tcp_wmem || true)
    IFS=' ' read -r rmin rdefault rmax <<< "$(printf '%s\n' "$tcp_rmem" | normalize_ws)"
    IFS=' ' read -r wmin wdefault wmax <<< "$(printf '%s\n' "$tcp_wmem" | normalize_ws)"
    if ! is_uint "${rmin:-}" || ! is_uint "${rdefault:-}" || ! is_uint "${rmax:-}"; then
        die "cannot parse net.ipv4.tcp_rmem: $tcp_rmem"
    fi
    if ! is_uint "${wmin:-}" || ! is_uint "${wdefault:-}" || ! is_uint "${wmax:-}"; then
        die "cannot parse net.ipv4.tcp_wmem: $tcp_wmem"
    fi

    core_rmem=$(max_uint "$core_rmem" "$target")
    core_wmem=$(max_uint "$core_wmem" "$target")
    rmax=$(max_uint "$rmax" "$target")
    wmax=$(max_uint "$wmax" "$target")

    add_install_setting net.ipv4.tcp_mtu_probing 1
    add_install_setting net.core.rmem_max "$core_rmem"
    add_install_setting net.core.wmem_max "$core_wmem"
    add_install_setting net.ipv4.tcp_rmem "$rmin $rdefault $rmax"
    add_install_setting net.ipv4.tcp_wmem "$wmin $wdefault $wmax"
    log "Safe optimization target: $target bytes (requested: $requested, existing larger values preserved)"
}

build_key_regex() {
    local regex='^[[:space:]]*(' separator='' key
    for key in "$@"; do
        key=${key//./\\.}
        regex+="${separator}${key}"
        separator='|'
    done
    regex+=')[[:space:]]*='
    printf '%s' "$regex"
}

add_install_setting net.core.default_qdisc fq
add_install_setting net.ipv4.tcp_congestion_control bbr
if [ "$OPTIMIZE" -eq 1 ]; then
    add_optimized_settings
fi
CLEAN_KEYS=("${INSTALL_KEYS[@]}" "${LEGACY_ADAPTIVE_KEYS[@]}")
CLEAN_REGEX=$(build_key_regex "${CLEAN_KEYS[@]}")

for path in "${LEGACY_SYSCTL_FILES[@]}" "${LEGACY_MODULE_FILES[@]}"; do
    if [ -e "$path" ]; then
        [ ! -L "$path" ] || die "refusing to modify legacy symlink: $path"
        FULL_REMOVE+=("$path")
    fi
done

is_full_remove() {
    local wanted=$1 existing
    for existing in "${FULL_REMOVE[@]}"; do
        [ "$wanted" = "$existing" ] && return 0
    done
    return 1
}

for path in /etc/sysctl.conf /etc/sysctl.d/*.conf; do
    [ -f "$path" ] || continue
    [ "$path" = "$TARGET_CONF" ] && continue
    is_full_remove "$path" && continue
    if [ "$path" != "/etc/sysctl.conf" ] && [ -e /etc/sysctl.conf ] &&
        [ "$path" -ef /etc/sysctl.conf ]; then
        continue
    fi
    if grep -Eq -- "$CLEAN_REGEX" "$path"; then
        [ ! -L "$path" ] || die "refusing to rewrite symlink with duplicate settings: $path"
        REWRITE_FILES+=("$path")
    fi
done

mkdir -p /etc/sysctl.d /etc/modules-load.d /var/lib
STATE_STAGING=$(mktemp -d /var/lib/bbr-clean-install.pending.XXXXXX) ||
    die "could not create backup state"
chmod 0700 "$STATE_STAGING"
mkdir -p "$STATE_STAGING/files"
: > "$STATE_STAGING/manifest.tsv"
: > "$STATE_STAGING/absent.list"

backup_path() {
    local path=$1 backup_name
    if [ -e "$path" ]; then
        BACKUP_INDEX=$((BACKUP_INDEX + 1))
        backup_name=$(printf '%04d' "$BACKUP_INDEX")
        cp -p -- "$path" "$STATE_STAGING/files/$backup_name"
        printf '%s\t%s\n' "$backup_name" "$path" >> "$STATE_STAGING/manifest.tsv"
    else
        printf '%s\n' "$path" >> "$STATE_STAGING/absent.list"
    fi
}

backup_path "$TARGET_CONF"
backup_path "$MODULE_CONF"
for path in "${FULL_REMOVE[@]}"; do
    backup_path "$path"
done
for path in "${REWRITE_FILES[@]}"; do
    backup_path "$path"
done

: > "$STATE_STAGING/runtime.before.conf"
for index in "${!INSTALL_KEYS[@]}"; do
    old_value=$(read_sysctl "${INSTALL_KEYS[$index]}" || true)
    [ -n "$old_value" ] || die "cannot read current ${INSTALL_KEYS[$index]}"
    printf '%s = %s\n' "${INSTALL_KEYS[$index]}" "$old_value" \
        >> "$STATE_STAGING/runtime.before.conf"
done
{
    printf 'version=%s\n' "$VERSION"
    printf 'created=%s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')"
    if [ "$OPTIMIZE" -eq 1 ]; then
        printf 'profile=optimized\n'
        printf 'bandwidth_mbps=%s\n' "$BANDWIDTH_MBPS"
        printf 'rtt_ms=%s\n' "$RTT_MS"
    else
        printf 'profile=minimal\n'
    fi
} > "$STATE_STAGING/metadata"
: > "$STATE_STAGING/pending"
mv -- "$STATE_STAGING" "$STATE_DIR"
STATE_STAGING=""

rollback() {
    warn "installation failed; restoring captured files and runtime values"
    if restore_state; then
        rm -rf -- "$STATE_DIR" || warn "could not remove restored state directory"
        warn "rollback completed"
    else
        warn "rollback was incomplete; run --uninstall using $STATE_DIR"
    fi
}

for path in "${FULL_REMOVE[@]}"; do
    rm -f -- "$path" || {
        rollback
        die "could not disable old configuration: $path"
    }
    log "Disabled old configuration: $path"
done

rewrite_index=0
CLEAN_KEYS_FILE="$WORK_DIR/clean.keys"
printf '%s\n' "${CLEAN_KEYS[@]}" > "$CLEAN_KEYS_FILE"
for path in "${REWRITE_FILES[@]}"; do
    rewrite_index=$((rewrite_index + 1))
    cleaned="$WORK_DIR/cleaned.$rewrite_index"
    if ! awk -v key_file="$CLEAN_KEYS_FILE" '
        BEGIN {
            while ((getline key < key_file) > 0) drop[key] = 1
            close(key_file)
        }
        {
            candidate = $0
            sub(/^[[:space:]]*/, "", candidate)
            if (candidate ~ /^[A-Za-z0-9_.]+[[:space:]]*=/) {
                key = candidate
                sub(/[[:space:]]*=.*/, "", key)
                if (key in drop) next
            }
            print
        }
    ' "$path" > "$cleaned"; then
        rollback
        die "could not clean duplicate definitions from $path"
    fi
    if ! atomic_rewrite "$cleaned" "$path"; then
        rollback
        die "could not update $path"
    fi
    log "Removed duplicate managed definitions: $path"
done

{
    printf '%s\n' "$MARKER"
    if [ "$OPTIMIZE" -eq 1 ]; then
        printf '# Profile: optimized (%s Mbps, %s ms RTT, %sx BDP headroom)\n' \
            "$BANDWIDTH_MBPS" "$RTT_MS" "$BDP_HEADROOM"
    else
        printf '# Profile: minimal\n'
    fi
    printf '# This is the only local file that should define the settings below.\n'
    for index in "${!INSTALL_KEYS[@]}"; do
        printf '%s = %s\n' "${INSTALL_KEYS[$index]}" "${INSTALL_VALUES[$index]}"
    done
} > "$TMP_CONF"
{
    printf '%s\n' "$MARKER"
    printf 'tcp_bbr\n'
    printf 'sch_fq\n'
} > "$TMP_MODULE"

if ! atomic_install "$TMP_CONF" "$TARGET_CONF" 0644; then
    rollback
    die "could not install $TARGET_CONF"
fi
if ! atomic_install "$TMP_MODULE" "$MODULE_CONF" 0644; then
    rollback
    die "could not install $MODULE_CONF"
fi
if ! sysctl -p "$TARGET_CONF"; then
    rollback
    die "the kernel rejected the clean BBR configuration"
fi

verification_failed=0
for index in "${!INSTALL_KEYS[@]}"; do
    actual_value=$(read_sysctl "${INSTALL_KEYS[$index]}" || true)
    actual_value=$(printf '%s\n' "$actual_value" | normalize_ws)
    expected_value=$(printf '%s\n' "${INSTALL_VALUES[$index]}" | normalize_ws)
    if [ "$actual_value" != "$expected_value" ]; then
        warn "verification failed for ${INSTALL_KEYS[$index]}: expected '$expected_value', got '${actual_value:-unavailable}'"
        verification_failed=1
    fi
done
if [ "$verification_failed" -ne 0 ]; then
    rollback
    die "one or more managed sysctls failed verification"
fi

actual_qdisc=$(read_sysctl net.core.default_qdisc || true)
actual_cc=$(read_sysctl net.ipv4.tcp_congestion_control || true)

mv -- "$STATE_DIR/pending" "$STATE_DIR/installed"

log "========================================"
log "Clean BBR installation completed"
log "Effective qdisc: $actual_qdisc"
log "Effective CC:    $actual_cc"
if [ "$OPTIMIZE" -eq 1 ]; then
    log "Profile:         optimized ($BANDWIDTH_MBPS Mbps / $RTT_MS ms)"
else
    log "Profile:         minimal"
fi
log "Config file:     $TARGET_CONF"
log "Recovery state:  $STATE_DIR"
log "========================================"
log "Run: bash bbr-clean-install.sh --status"
log "Reboot once when convenient so removed legacy tunings return to kernel defaults."
log "Docker-related forwarding and unrelated /etc/sysctl.conf settings were preserved."
