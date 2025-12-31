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
    local show_ip=$(get_public_ip)
    echo -e "\n${GREEN}==============================================${PLAIN}"
    echo -e "${GREEN}          frps 服务端部署/更新成功！          ${PLAIN}"
    echo -e "${GREEN}==============================================${PLAIN}"
    echo -e "${YELLOW}【客户端连接信息】${PLAIN}"
    echo -e "服务器公网 IP : ${CYAN}${show_ip}${PLAIN}"
    echo -e "服务绑定端口  : ${CYAN}${bind_port}${PLAIN}"
    echo -e "认证 Token    : ${CYAN}${token}${PLAIN}"
    echo -e "----------------------------------------------"
    echo -e "${YELLOW}【仪表盘管理后台】${PLAIN}"
    echo -e "访问地址      : ${CYAN}http://${show_ip}:${dash_port}${PLAIN}"
    echo -e "管理用户      : ${CYAN}${dash_user}${PLAIN}"
    echo -e "管理密码      : ${CYAN}${dash_pwd}${PLAIN}"
    echo -e "${GREEN}==============================================${PLAIN}"
}

# --- 服务端交互配置 ---
config_frps() {
    echo -e "\n${YELLOW}>>> 开始服务端交互配置${PLAIN}"
    local detected_ip=$(get_public_ip)
    read -p "1. 监听地址 (IPv4) [默认: 0.0.0.0]: " bind_addr
    bind_addr=${bind_addr:-0.0.0.0}

    read -p "2. 绑定监听端口 [默认: 8055]: " bind_port
    bind_port=${bind_port:-8055}

    local rand_token=$(generate_random 16)
    read -p "3. 设置认证 Token [默认: $rand_token]: " token
    token=${token:-$rand_token}

    read -p "4. 仪表盘端口 [默认: 7500]: " dash_port
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

# --- 具体的部署动作 ---
install_frp_system() {
    local type=$1
    get_arch
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

install_frp_docker() {
    local type=$1
    local DOCKER_TAG="v${FRP_VERSION_NUM}"
    check_docker
    docker pull fatedier/$type:$DOCKER_TAG
    docker rm -f $type &>/dev/null
    docker run -d --name $type --restart always --network host \
        -v $BASE_DIR/${type}.toml:/etc/frp/${type}.toml fatedier/$type:$DOCKER_TAG \
        $type -c /etc/frp/${type}.toml
    if [ "$type" == "frps" ]; then sleep 2 && show_frps_info; fi
}

# --- 客户端配置 ---
config_frpc() {
    read -p "服务器 IP: " s_addr
    until [[ -n "$s_addr" ]]; do read -p "不能为空: " s_addr; done
    read -p "端口 [8055]: " s_port
    s_port=${s_port:-8055}
    read -p "Token: " s_token
    until [[ -n "$s_token" ]]; do read -p "不能为空: " s_token; done
    mkdir -p $BASE_DIR
    cat > $BASE_DIR/frpc.toml <<EOF
serverAddr = "$s_addr"
serverPort = $s_port
auth.token = "$s_token"
EOF
}

manage_apps() {
    if [[ ! -f "$BASE_DIR/frpc.toml" ]]; then echo "请先安装客户端！"; return; fi
    read -p "应用名: " name
    read -p "本地端口: " l_port
    read -p "外网端口: " r_port
    cat >> $BASE_DIR/frpc.toml <<EOF

[[proxies]]
name = "$name"
type = "tcp"
localIP = "127.0.0.1"
localPort = $l_port
remotePort = $r_port
EOF
    if docker ps | grep -q frpc; then docker restart frpc; else systemctl restart frpc; fi
    echo "应用已添加！"
}

# --- 主菜单 ---
menu() {
    clear
    echo -e "${GREEN}frp 全能版一键脚本${PLAIN}"
    echo "--------------------------------"
    echo "1. 安装服务端 (frps) - 原生模式"
    echo "2. 安装服务端 (frps) - Docker 模式"
    echo "3. 安装客户端 (frpc) - 原生模式"
    echo "4. 安装客户端 (frpc) - Docker 模式"
    echo "5. 客户端应用管理 (添加转发)"
    echo "6. 彻底卸载 frp"
    echo "0. 退出脚本"
    echo "--------------------------------"
    read -p "请输入选项: " main_opt

    case $main_opt in
        1) config_frps && install_frp_system frps ;;
        2) config_frps && install_frp_docker frps ;;
        3) config_frpc && install_frp_system frpc ;;
        4) config_frpc && install_frp_docker frpc ;;
        5) manage_apps ;;
        6)
            systemctl stop frps frpc &>/dev/null
            docker rm -f frps frpc &>/dev/null
            rm -rf $BASE_DIR $BIN_DIR/frp* /etc/systemd/system/frp*.service
            echo "清理完成。"
            ;;
        *) exit 0 ;;
    esac
}

# 启动脚本
menu
