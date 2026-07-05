#!/bin/bash

echo "=============================="
echo " BBR Adaptive v3.5 Enterprise Stable"
echo "=============================="

# =========================
# 1. 依赖
# =========================
apt update -y
apt install -y curl iputils-ping ca-certificates bc >/dev/null 2>&1

# =========================
# 2. CPU
# =========================
CPU_CORE=$(nproc)

if [ "$CPU_CORE" -le 1 ]; then
    CPU_LEVEL="low"
elif [ "$CPU_CORE" -le 2 ]; then
    CPU_LEVEL="medium"
else
    CPU_LEVEL="high"
fi

echo "CPU Level: $CPU_LEVEL"

# =========================
# 3. IPv4优先 / IPv6 fallback
# =========================
PING_TARGET=""

if ping -c 1 -W 1 1.1.1.1 >/dev/null 2>&1; then
    PING_TARGET="ipv4"
elif ping -6 -c 1 -W 1 2606:4700:4700::1111 >/dev/null 2>&1; then
    PING_TARGET="ipv6"
else
    PING_TARGET="none"
fi

echo "Network: $PING_TARGET"

# =========================
# 4. TCP真实延迟（核心升级）
# =========================
tcp_ping() {
    local host=$1
    start=$(date +%s%N)
    curl -s --connect-timeout 2 --max-time 2 "$host" >/dev/null 2>&1
    end=$(date +%s%N)

    if [ $? -eq 0 ]; then
        echo $(( (end - start) / 1000000 ))
    else
        echo 999
    fi
}

if [ "$PING_TARGET" = "ipv4" ]; then
    LATENCY=$(tcp_ping "https://1.1.1.1")
elif [ "$PING_TARGET" = "ipv6" ]; then
    LATENCY=$(tcp_ping "https://[2606:4700:4700::1111]")
else
    LATENCY=999
fi

echo "TCP Latency: ${LATENCY}ms"

# =========================
# 5. 丢包检测（稳定版）
# =========================
if [ "$PING_TARGET" = "ipv4" ]; then
    LOSS=$(ping -c 5 -W 1 1.1.1.1 | grep -oP '\d+(?=% packet loss)' | head -1)
elif [ "$PING_TARGET" = "ipv6" ]; then
    LOSS=$(ping -6 -c 5 -W 1 2606:4700:4700::1111 | grep -oP '\d+(?=% packet loss)' | head -1)
else
    LOSS=100
fi

[ -z "$LOSS" ] && LOSS=100

echo "Loss: ${LOSS}%"

# =========================
# 6. 带宽检测
# =========================
if [ "$PING_TARGET" = "ipv4" ]; then
    SPEED=$(curl -4 -o /dev/null -s -w "%{speed_download}" https://speed.cloudflare.com/__down?bytes=20000000)
else
    SPEED=$(curl -6 -o /dev/null -s -w "%{speed_download}" https://speed.cloudflare.com/__down?bytes=20000000)
fi

SPEED_MBPS=$(echo "$SPEED * 8 / 1000000" | bc -l 2>/dev/null)
SPEED_INT=${SPEED_MBPS%.*}
[ -z "$SPEED_INT" ] && SPEED_INT=0

echo "Bandwidth: $SPEED_INT Mbps"

# =========================
# 7. 三档带宽
# =========================
if [ "$SPEED_INT" -lt 200 ]; then
    BANDWIDTH="low"
elif [ "$SPEED_INT" -lt 700 ]; then
    BANDWIDTH="medium"
else
    BANDWIDTH="high"
fi

# =========================
# 8. jitter（抖动检测）
# =========================
JITTER=$(ping -c 5 1.1.1.1 | awk -F '/' 'END{print $4}')
[ -z "$JITTER" ] && JITTER=0

echo "Jitter: ${JITTER}ms"

# =========================
# 9. 健康评分 v2
# =========================
SCORE=100

# latency
if [ "$LATENCY" -gt 200 ]; then SCORE=$((SCORE - 30)); fi
if [ "$LATENCY" -gt 100 ]; then SCORE=$((SCORE - 15)); fi

# loss
if [ "$LOSS" -gt 5 ]; then SCORE=$((SCORE - 40)); fi
if [ "$LOSS" -gt 1 ]; then SCORE=$((SCORE - 20)); fi

# jitter
if (( $(echo "$JITTER > 20" | bc -l) )); then SCORE=$((SCORE - 15)); fi

echo "Score: $SCORE"

# =========================
# 10. 模式
# =========================
if [ "$SCORE" -ge 80 ]; then
    MODE="aggressive"
elif [ "$SCORE" -ge 50 ]; then
    MODE="balanced"
else
    MODE="stable"
fi

echo "Mode: $MODE"

# =========================
# 11. sysctl（TCP+UDP）
# =========================
cat > /etc/sysctl.d/99-bbr-v3.5.conf <<EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.ip_forward = 1

fs.file-max = 1048576
vm.swappiness = 10
vm.vfs_cache_pressure = 90

net.core.somaxconn = 8192
net.core.netdev_max_backlog = 8192
net.ipv4.tcp_max_syn_backlog = 8192

net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_max_tw_buckets = 200000

# UDP
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
EOF

# =========================
# 12. 模式调优
# =========================
if [ "$MODE" = "aggressive" ]; then

cat > /etc/sysctl.d/20-mode.conf <<EOF
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.tcp_fin_timeout = 10
EOF

elif [ "$MODE" = "balanced" ]; then

cat > /etc/sysctl.d/20-mode.conf <<EOF
net.core.netdev_max_backlog = 12288
net.ipv4.tcp_max_syn_backlog = 12288
net.ipv4.tcp_fin_timeout = 15
EOF

else

cat > /etc/sysctl.d/20-mode.conf <<EOF
net.core.netdev_max_backlog = 8192
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_fin_timeout = 20
EOF

fi

# =========================
# APPLY
# =========================
sysctl --system >/dev/null 2>&1

echo "=============================="
echo " DONE"
echo " CPU: $CPU_LEVEL"
echo " BANDWIDTH: $BANDWIDTH"
echo " MODE: $MODE"
echo " SCORE: $SCORE"
echo " LATENCY: ${LATENCY}ms"
echo " LOSS: ${LOSS}%"
echo " JITTER: ${JITTER}ms"
echo "=============================="
