# 🚀 BBR Adaptive Optimizer (v3.5 Enterprise Stable)

一个适用于全球 VPS（美国 / 香港 / 日本 / 新加坡 / 墨西哥等）的  
**自动 BBR + TCP/UDP + 智能网络健康评分优化工具**

---

## 📌 核心能力

- 🚀 自动启用 BBR 拥塞控制算法
- 🌐 IPv4 / IPv6 双栈自适应
- ⚡ TCP + UDP 双协议优化
- 🧠 自动 CPU 分级优化
- 📶 自动带宽识别（100M / 1G / 分级模型）
- 📊 网络健康评分系统（v2）
- 📉 延迟 / 丢包 / 抖动综合评估
- 🔧 自动 sysctl 性能调优

---

## ⚙️ 适用系统

- Debian 10 / 11 / 12
- Ubuntu 20.04 / 22.04 / 24.04

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
2️⃣ 添加执行权限

```bash
chmod +x bbr.sh

```
3️⃣ 运行脚本

```bash
bash bbr.sh
```
