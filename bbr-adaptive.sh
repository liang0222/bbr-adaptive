#!/bin/bash

echo "=============================="
echo " BBR CPU + Bandwidth Adaptive"
echo "=============================="

# =========================
# 1. 依赖安装
# =========================
echo "[1/6] Installing dependencies..."

apt update -y
apt install -y curl iputils-ping ca-certificates bc >/dev/null 2>&1

# =========================
# 2. CPU 识别
# =========================
echo "[2/6] Detecting CPU..."

CPU_CORE=$(nproc)

echo "CPU Cores: $CPU_CORE"

if [ "$CPU_CORE" -le 1 ]; then
    CPU_LEVEL="low"
elif [ "$CPU_CORE" -le 2 ]; then
    CPU_LEVEL="medium"
else
    CPU_LEVEL="high"
fi

echo "CPU Level: $CPU_LEVEL"

# =========================
# 3. 带宽检测
# =========================
echo "[3/6] Testing bandwidth..."

SPEED=$(curl -o /dev/null -s -w "%{speed_download}" https://speed.cloudflare.com/__down?bytes=30000000)

SPEED_MBPS=$(echo "$SPEED * 8 / 1000000" | bc -l)
SPEED_INT=${SPEED_MBPS%.*}

echo "Bandwidth: $SPEED_INT Mbps"

if [ "$SPEED_INT" -ge 800 ]; then
    BANDWIDTH="1G"
else
    BANDWIDTH="100M"
fi

echo "Bandwidth Class: $BANDWIDTH"

# =========================
# 4. sysctl 基础（BBR核心）
# =========================
echo "[4/6] Writing base sysctl..."

cat > /etc/sysctl.d/99-bbr.conf <<EOF
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
EOF

# =========================
# 5. 带宽自适应优化
# =========================
echo "[5/6] Applying bandwidth tuning..."

if [ "$BANDWIDTH" = "1G" ]; then
cat > /etc/sysctl.d/20-bandwidth.conf <<EOF
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.tcp_fin_timeout = 10
EOF
else
cat > /etc/sysctl.d/20-bandwidth.conf <<EOF
net.core.netdev_max_backlog = 8192
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_fin_timeout = 20
EOF
fi

# =========================
# 6. CPU 微调（轻量）
# =========================
echo "[6/6] Applying CPU tuning..."

if [ "$CPU_LEVEL" = "high" ]; then
cat > /etc/sysctl.d/30-cpu.conf <<EOF
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_moderate_rcvbuf = 1
EOF

elif [ "$CPU_LEVEL" = "medium" ]; then
cat > /etc/sysctl.d/30-cpu.conf <<EOF
net.ipv4.tcp_window_scaling = 1
EOF

else
cat > /etc/sysctl.d/30-cpu.conf <<EOF
# minimal CPU tuning
EOF
fi

# =========================
# APPLY
# =========================
sysctl --system >/dev/null 2>&1

echo "=============================="
echo " DONE"
echo " CPU Level: $CPU_LEVEL"
echo " Bandwidth: $BANDWIDTH"
echo "=============================="
