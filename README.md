# 🚀 frp 全能一键安装管理脚本

![License](https://img.shields.io/badge/license-MIT-blue.svg)
![Platform](https://img.shields.io/badge/platform-Linux-lightgrey.svg)
![Docker](https://img.shields.io/badge/docker-support-blue.svg)

这是一个简单、高效的 frp (Fast Reverse Proxy) 一键部署脚本。支持**普通系统安装**与 **Docker 容器化安装**两种模式，完美适配最新的 **TOML** 配置格式。

---

## 📖 脚本简介

本脚本旨在简化 frp 的安装与配置过程，通过交互式对话完成参数设置，无需手动编辑复杂的配置文件。



### 主要功能
- **双模式支持**：支持传统 Systemd 守护进程安装和 Docker 容器化部署。
- **自动环境检测**：自动识别系统架构（amd64/arm64），自动安装 Docker 环境。
- **智能交互配置**：端口、Token、仪表盘账号密码均可自定义或自动随机生成。
- **应用管理**：支持交互式添加客户端转发服务（Proxies），修改后自动重启生效。
- **最新版适配**：全面支持 frp v0.52.0+ 引入的 TOML 配置格式。

---

## ⚡ 快速开始

在你的 Linux 终端执行以下命令即可启动：

```bash
wget -N https://raw.githubusercontent.com/509992828/frp-onekey/main/frp.sh && chmod +x frp.sh && ./frp.sh
