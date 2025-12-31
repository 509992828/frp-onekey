#!/bin/bash

# 颜色定义
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

# --- 基础变量配置 ---
FRP_VERSION_NUM="0.61.0" 
BASE_DIR="/etc/frp"
BIN_DIR="/usr/local/bin"

# 检查权限
[[ $EUID -ne 0 ]] && echo -e "${RED}错误：必须使用 root 运行！${PLAIN}" && exit 1

# --- 工具函数 ---
get_public_ip() {
    local ip=$(curl -s -4 --connect-timeout 5 https://api64.ipify.org | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}')
    [[ -z "$ip" ]] && ip=$(curl -s -4 --connect-timeout 5 ifconfig.me | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}')
    echo "$ip"
}

check_docker() {
    if ! command -v docker &> /dev/null; then
        echo -e "${YELLOW}未检测到 Docker，正在安装...${PLAIN}"
        curl -fsSL https://get.docker.com | bash -s docker
        systemctl start docker && systemctl enable docker
    fi
}

get_arch() {
    arch=$(uname -m)
    case $arch in
        x86_64) arch="amd64" ;;
        aarch64) arch="arm64" ;;
        *) echo -e "${RED}不支持的架构${PLAIN}"; exit 1 ;;
    esac
}

generate_random() {
    cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w $1 | head -n 1
}

# --- 结果展示面板 ---
show_frps_info() {
    echo -e "\n${GREEN}==============================================${PLAIN}"
    echo -e "${GREEN}          frps 服务端部署/更新成功！          ${PLAIN}"
    echo -e "${GREEN}==============================================${PLAIN}"
    echo -e "${YELLOW}【客户端连接信息】${PLAIN}"
    echo -e "服务器公网 IP : ${CYAN}${pub_ip}${PLAIN}"
    echo -e "服务绑定端口  : ${CYAN}${bind_port}${PLAIN}"
    echo -e "认证 Token    : ${CYAN}${token}${PLAIN}"
    echo -e "----------------------------------------------"
    echo -e "${YELLOW}【仪表盘管理后台】${PLAIN}"
    echo -e "访问地址      : ${CYAN}http://${pub_ip}:${dash_port}${PLAIN}"
    echo -e "管理用户      : ${CYAN}${dash_user}${PLAIN}"
    echo -e "管理密码      : ${CYAN}${dash_pwd}${PLAIN}"
    echo -e "${GREEN}==============================================${PLAIN}"
    echo -e "${RED}注意：请务必在云平台安全组放行 TCP 端口: ${bind_port} 和 ${dash_port}${PLAIN}\n"
}

# --- 服务端交互配置 ---
config_frps() {
    echo -e "\n${YELLOW}>>> 开始服务端配置 (IPv4)${PLAIN}"
    pub_ip=$(get_public_ip)
    [[ -z "$pub_ip" ]] && pub_ip="0.0.0.0"

    echo -e "检测到服务器公网 IP: ${CYAN}${pub_ip}${PLAIN}"
    read -p "1. 监听地址 (建议 0.0.0.0) [默认: 0.0.0.0]: " bind_addr
    bind_addr=${bind_addr:-0.0.0.0}

    read -p "2. 绑定监听端口 [默认: 8055]: " bind_port
    bind_port=${bind_port:-8055}

    local rand_token=$(generate_random 16)
    read -p "3. 设置认证 Token [默认: $rand_token]: " token
    token=${token:-$rand_token}

    read -p "4. 仪表盘(面板)端口 [默认: 7500]: " dash_port
    dash_port=${dash_port:-7500}

    read -p "5. 仪表盘用户名 [默认: admin]: " dash_user
    dash_user=${dash_user:-admin}

    local rand_pwd=$(generate_random 12)
    read -p "6. 仪表盘密码 [默认: $rand_pwd]: " dash_pwd
    dash_pwd=${dash_pwd:-$rand_pwd}

    mkdir -p $BASE_DIR
    cat > $BASE_DIR/frps.toml <<EOF
bindAddr = "$bind_addr"
bindPort = $bind_port
auth.token = "$token"
webServer.addr = "0.0.0.0"
webServer.port = $dash_port
webServer.user = "$dash_user"
webServer.password = "$dash_pwd"
EOF
    chmod 644 $BASE_DIR/frps.toml
}

# --- 客户端交互配置 ---
config_frpc() {
    echo -e "\n${YELLOW}>>> 开始客户端基础配置${PLAIN}"
    read -p "1. 服务器公网 IPv4 地址: " s_addr
    until [[ -n "$s_addr" ]]; do read -p "${RED}不能为空: ${PLAIN}" s_addr; done

    read -p "2. 服务器监听端口 [默认: 8055]: " s_port
    s_port=${s_port:-8055}

    read -p "3. 服务器 Token: " s_token
    until [[ -n "$s_token" ]]; do read -p "${RED}不能为空: ${PLAIN}" s_token; done

    mkdir -p $BASE_DIR
    cat > $BASE_DIR/frpc.toml <<EOF
serverAddr = "$s_addr"
serverPort = $s_port
auth.token = "$s_token"
EOF
}

# --- 部署动作 ---
install_frp_system() {
    local type=$1
    get_arch
    echo -e "${YELLOW}正在安装原生二进制文件...${PLAIN}"
    wget https://github.com/fatedier/frp/releases/download/v${FRP_VERSION_NUM}/frp_${FRP_VERSION_NUM}_linux_${arch}.tar.gz -O frp.tar.gz
    tar -zxvf frp.tar.gz
    cp frp_${FRP_VERSION_NUM}_linux_${arch}/$type $BIN_DIR/
    rm -rf frp.tar.gz frp_${FRP_VERSION_NUM}_linux_${arch}
    
    cat > /etc/systemd/system/${type}.service <<EOF
[Unit]
Description=frp $type service
After=network.target
[Service]
Type=simple
ExecStart=$BIN_DIR/$type -c $BASE_DIR/${type}.toml
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable $type && systemctl restart $type
    if [ "$type" == "frps" ]; then show_frps_info; fi
}

install_frp_
