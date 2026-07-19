# 🚀 BBR Adaptive Optimizer (v3.5 Enterprise Stable)

一个适用于全球 VPS（美国 / 香港 / 日本 / 新加坡 / 墨西哥等）的
**自动 BBR + TCP/UDP + 智能网络健康评分优化工具**

自动检测网络状态，根据延迟、丢包、带宽、抖动智能评分，并选择最优调优模式。

---

## 📌 核心能力

- 🚀 自动启用 BBR 拥塞控制算法
- 🌐 IPv4 / IPv6 双栈自适应
- ⚡ TCP + UDP 双协议优化
- 🧠 自动 CPU 分级优化
- 📶 自动带宽识别（分级模型）
- 📊 网络健康评分系统（v2）
- 📉 延迟 / 丢包 / 抖动综合评估
- 🔧 自动 sysctl 性能调优
- ✅ 执行完成后验证 BBR 是否真正启用

---

## 📖 目录

- [适用系统](#️-适用系统)
- [一键安装](#-一键安装推荐)
- [手动安装](#手动安装生产推荐)
- [预期输出](#-预期输出示例)
- [工作原理](#-工作原理)
- [参数说明](#-参数说明)
- [模式对比](#-模式对比)
- [常见问题](#-常见问题)
- [修复记录](#-修复记录)

---

## ⚙️ 适用系统

| 项目 | 要求 |
|------|------|
| 操作系统 | Debian 10 / 11 / 12，Ubuntu 20.04 / 22.04 / 24.04（依赖 `apt`） |
| 内核版本 | ≥ 4.9（BBR 最低支持版本），推荐 ≥ 5.x |
| 权限 | **root** 或 `sudo` |
| 网络 | 可访问 `1.1.1.1` 或 `2606:4700:4700::1111` |

> 查看内核版本：`uname -r`

---

## 🚀 一键安装（推荐）

```bash
bash <(curl -Ls https://raw.githubusercontent.com/liang0222/bbr-adaptive/main/bbr-adaptive.sh)
```

## 手动安装（生产推荐）

1️⃣ 下载脚本

```bash
curl -L -o bbr.sh https://raw.githubusercontent.com/liang0222/bbr-adaptive/main/bbr-adaptive.sh
```


2下载脚本

```bash
curl -L -o bbr-clean-install.sh https://raw.githubusercontent.com/liang0222/bbr-adaptive/main/bbr-clean-install.sh && \
chmod +x bbr-clean-install.sh && \
bash bbr-clean-install.sh --uninstall || true && \
bash bbr-clean-install.sh
```

2️⃣ 添加执行权限

```bash
chmod +x bbr.sh
```

3️⃣ 运行脚本（需 root）

```bash
sudo bash bbr.sh
```

---

## 📺 预期输出示例

```
==============================
 BBR Adaptive v3.5 Enterprise Stable
==============================
CPU Level: high
Network: ipv4
TCP Latency: 12ms
Loss: 0%
Bandwidth: 850 Mbps
Jitter: 1.23ms
Score: 100
Mode: aggressive
==============================
 DONE
 CPU: high
 BANDWIDTH: high
 MODE: aggressive
 SCORE: 100
 LATENCY: 12ms
 LOSS: 0%
 JITTER: 1.23ms
 CONGESTION: bbr
 QDISC: fq
==============================
✅ BBR 已成功启用。
```

---

## 🧠 工作原理

脚本按以下顺序执行：

```
检查 root → 安装依赖 → 验证 BBR 内核支持
    ↓
检测网络（IPv4 优先 / IPv6 fallback）
    ↓
测量延迟 → 测量丢包 → 测量带宽 → 测量抖动
    ↓
计算健康评分（满分 100）
    ↓
选择调优模式（aggressive / balanced / stable）
    ↓
写入 sysctl 配置 → 应用 → 验证生效
```

---

## 📊 参数说明

### 健康评分规则

| 指标 | 条件 | 扣分 |
|------|------|------|
| 延迟 | > 100ms | -15 |
| 延迟 | > 200ms | 额外 -30（累计 -45） |
| 丢包 | > 1% | -20 |
| 丢包 | > 5% | 额外 -40（累计 -60） |
| 抖动 | > 20ms | -15 |
| 下限 | — | 最低 0 分 |

### 带宽档位

| 档位 | 条件 |
|------|------|
| low | < 200 Mbps |
| medium | 200 ~ 700 Mbps |
| high | ≥ 700 Mbps |

### CPU 分级

| 档位 | 条件 |
|------|------|
| low | 1 核 |
| medium | 2 核 |
| high | ≥ 3 核 |

---

## ⚖️ 模式对比

| 参数 | aggressive（高性能） | balanced（均衡） | stable（稳定） |
|------|-------------------|--------------------|---------------|
| 触发评分 | ≥ 80 | 50 ~ 79 | < 50 |
| netdev_max_backlog | 16384 | 12288 | 8192 |
| tcp_max_syn_backlog | 16384 | 12288 | 8192 |
| tcp_fin_timeout | 10s | 15s | 20s |
| 适用场景 | 低延迟、高带宽服务器 | 普通 VPS | 高丢包、不稳定网络 |

### 通用 sysctl 参数（所有模式）

| 参数 | 值 | 说明 |
|------|----|------|
| `net.core.default_qdisc` | fq | 公平队列，配合 BBR 使用 |
| `net.ipv4.tcp_congestion_control` | bbr | 启用 BBR |
| `net.ipv4.tcp_fastopen` | 3 | 客户端+服务端均开启 TCP Fast Open |
| `net.ipv4.tcp_mtu_probing` | 1 | 自动 MTU 探测 |
| `net.ipv4.tcp_slow_start_after_idle` | 0 | 禁用空闲后慢启动 |
| `net.ipv4.ip_forward` | 1 | 开启 IP 转发（VPN/代理场景需要） |
| `fs.file-max` | 1048576 | 最大文件句柄数 |
| `vm.swappiness` | 10 | 减少 swap 使用 |
| `net.core.rmem_max` / `wmem_max` | 128MB | UDP 缓冲区上限 |

> **注意**：`ip_forward = 1` 会将服务器变为路由器，仅在需要转发流量（如 VPN、代理）时保留。普通 Web 服务器建议改为 `0`。

---

## ❓ 常见问题

**Q：执行提示"当前内核不支持 BBR"？**

内核版本需 ≥ 4.9，推荐升级：
```bash
# Debian/Ubuntu 升级内核
apt install linux-image-generic -y
reboot
```

**Q：`sysctl --system` 报错怎么办？**

脚本会打印具体错误行，常见原因：
- 参数名拼写错误（极少见）
- 旧内核不支持某些参数（如 `udp_rmem_min`，4.15+ 才有）

可手动检查：
```bash
sysctl -p /etc/sysctl.d/99-bbr-v3.5.conf
```

**Q：执行完 BBR 显示未生效？**

```bash
# 手动验证
sysctl net.ipv4.tcp_congestion_control
sysctl net.core.default_qdisc

# 如未生效，手动加载模块
modprobe tcp_bbr
sysctl -w net.ipv4.tcp_congestion_control=bbr
```

**Q：需要重启吗？**

不需要。`sysctl --system` 立即生效，重启后也会自动加载 `/etc/sysctl.d/` 下的配置。

**Q：如何恢复默认设置？**

```bash
rm /etc/sysctl.d/99-bbr-v3.5.conf /etc/sysctl.d/20-mode.conf
sysctl --system
```

---

## 🛠 修复记录

| 版本 | 修复内容 |
|------|---------|
| v3.5-fix | 修复 `tcp_ping()` 中 `$?` 检查的是 `date` 而非 `curl` 的退出码 |
| v3.5-fix | 修复 Jitter 检测硬编码 IPv4，现在正确跟随 `PING_TARGET` |
| v3.5-fix | 修复带宽测试在 `PING_TARGET=none` 时错误走 IPv6 分支 |
| v3.5-fix | 新增 root 权限检查，未授权时直接退出 |
| v3.5-fix | 新增 BBR 内核支持检测，不支持时提前报错退出 |
| v3.5-fix | `sysctl --system` 不再静默，错误可见 |
| v3.5-fix | 执行完成后打印实际生效的拥塞算法和队列规则 |
| v3.5-fix | 评分增加下限 0，防止出现负分 |

---

## 🌍 已测试地区

美国 / 香港 / 日本 / 新加坡 / 墨西哥 等主流 VPS 节点。
