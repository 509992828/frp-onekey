#!/bin/bash

# 颜色
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

FRP_VERSION_NUM="0.61.0" 
BASE_DIR="/etc/frp"
BIN_DIR="/usr/local/bin"

[[ $EUID -ne 0 ]] && echo -e "${RED}错误：请使用 root 运行！${PLAIN}" && exit 1

# 工具函数
get_public_ip() {
    local ip=$(curl -s -4 --connect-timeout 5 https://api64.ipify.org | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}')
    [[ -z "$ip" ]] && ip=$(curl -s -4 --connect-timeout 5 ifconfig.me | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}')
    echo "$ip"
}

check_docker() {
    if ! command -v docker &> /dev/null; then
        echo -e "${YELLOW}正在安装 Docker...${PLAIN}"
        curl -fsSL https://get.docker.com | bash -s docker
        systemctl start docker && systemctl enable docker
    fi
}

get_arch() {
    arch=$(uname -m)
    case $arch in
        x86_64) arch="amd64" ;;
        aarch64) arch="arm64" ;;
        *) arch="amd64" ;;
    esac
}

generate_random() {
    cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w $1 | head -n 1
}

# 服务端配置
config_frps() {
    echo -e "\n${YELLOW}>>> 服务端配置${PLAIN}"
    pub_ip=$(get_public_ip)
    echo -e "当前服务器 IPv4: ${CYAN}${pub_ip}${PLAIN}"
    
    # 强制默认 0.0.0.0 以避免绑定失败
    read -p "1. 监听地址 [默认: 0.0.0.0]: " bind_addr
    bind_addr=${bind_addr:-0.0.0.0}

    read -p "2. 绑定端口 [默认: 8055]: " bind_port
    bind_port=${bind_port:-8055}

    local r_token=$(generate_random 16)
    read -p "3. 认证 Token [默认: $r_token]: " token
    token=${token:-$r_token}

    read -p "4. 面板端口 [默认: 7500]: " dash_port
    dash_port=${dash_port:-7500}

    read -p "5. 面板用户 [默认: admin]: " dash_user
    dash_user=${dash_user:-admin}

    local r_pwd=$(generate_random 12)
    read -p "6. 面板密码 [默认: $r_pwd]: " dash_pwd
    dash_pwd=${dash_pwd:-$r_pwd}

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

show_frps_info() {
    echo -e "\n${GREEN}==============================================${PLAIN}"
    echo -e "          frps 服务端部署成功！               "
    echo -e "==============================================${PLAIN}"
    echo -e "服务器地址   : ${CYAN}${pub_ip}${PLAIN}"
    echo -e "服务端口     : ${CYAN}${bind_port}${PLAIN}"
    echo -e "认证 Token   : ${CYAN}${token}${PLAIN}"
    echo -e "----------------------------------------------"
    echo -e "管理面板     : ${CYAN}http://${pub_ip}:${dash_port}${PLAIN}"
    echo -e "管理账号     : ${CYAN}${dash_user}${PLAIN} / ${CYAN}${dash_pwd}${PLAIN}"
    echo -e "${GREEN}==============================================${PLAIN}\n"
}

# 部署
install_frp_docker() {
    local type=$1
    local TAG="v${FRP_VERSION_NUM}"
    check_docker
    docker rm -f $type &>/dev/null
    docker pull fatedier/$type:$TAG

    docker run -d --name $type --restart always --network host \
        -v $BASE_DIR/${type}.toml:/etc/frp/${type}.toml \
        fatedier/$type:$TAG $type -c /etc/frp/${type}.toml

    sleep 3
    # 关键：尝试自动放行本地 UFW 防火墙
    if command -v ufw &> /dev/null; then
        ufw allow $bind_port/tcp >/dev/null
        ufw allow $dash_port/tcp >/dev/null
        ufw reload >/dev/null
    fi

    if docker ps | grep -q $type; then
        if [ "$type" == "frps" ]; then show_frps_info; fi
    else
        echo -e "${RED}启动失败，请检查 docker logs frps${PLAIN}"
    fi
}

# 菜单逻辑
menu() {
    clear
    echo -e "${GREEN}frp 全能版一键脚本${PLAIN}"
    echo "1. 安装服务端 (frps) - 系统原生"
    echo "2. 安装服务端 (frps) - Docker 模式"
    echo "3. 彻底卸载"
    echo "0. 退出"
    read -p "请选择: " opt
    case $opt in
        1) config_frps && install_frp_system frps ;;
        2) config_frps && install_frp_docker frps ;;
        3) docker rm -f frps &>/dev/null; rm -rf $BASE_DIR; echo "清理完成" ;;
        *) exit 0 ;;
    esac
}

# 启动调用
menu
