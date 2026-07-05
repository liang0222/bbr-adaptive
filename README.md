# 🚀 BBR Adaptive Optimizer

一个适用于多地区 VPS（美国 / 香港 / 日本 / 新加坡 / 墨西哥等）的  
**自动 BBR + TCP/UDP + CPU + 带宽自适应优化脚本**

---

## 📌 功能特点

- ✅ 自动启用 BBR TCP 拥塞控制
- ✅ TCP/UDP 网络栈优化
- ✅ 自动识别 CPU 核心数
- ✅ 自动检测 VPS 带宽（100M / 1G）
- ✅ 按性能自动分级优化
- ✅ 适配多国家 / 多线路 VPS
- ✅ 一键执行，无需手动配置

---

## ⚙️ 支持系统

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
