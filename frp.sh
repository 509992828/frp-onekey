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
get_ip() {
    local ip=$(curl -s https://api64.ipify.org || curl -s ifconfig.me || curl -s ip.sb)
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
    local server_ip=$(get_ip)
    echo -e "\n${GREEN}==============================================${PLAIN}"
    echo -e "${GREEN}          frps 服务端部署/更新成功！          ${PLAIN}"
    echo -e "${GREEN}==============================================${PLAIN}"
    echo -e "${YELLOW}【客户端连接参考信息】${PLAIN}"
    echo -e "服务器 IP   : ${CYAN}${server_ip}${PLAIN}"
    echo -e "服务端口     : ${CYAN}${bind_port}${PLAIN}"
    echo -e "认证 Token   : ${CYAN}${token}${PLAIN}"
    echo -e "----------------------------------------------"
    echo -e "${YELLOW}【仪表盘管理后台】${PLAIN}"
    echo -e "访问地址     : ${CYAN}http://${server_ip}:${dash_port}${PLAIN}"
    echo -e "管理用户     : ${CYAN}${dash_user}${PLAIN}"
    echo -e "管理密码     : ${CYAN}${dash_pwd}${PLAIN}"
    echo -e "${GREEN}==============================================${PLAIN}"
    echo -e "${YELLOW}请确保安全组/防火墙已放行以上所有端口！${PLAIN}\n"
}

# --- 服务端交互配置 ---
config_frps() {
    echo -e "\n${YELLOW}>>> 开始服务端配置${PLAIN}"
    read -p "1. 绑定监听端口 [默认: 8055]: " bind_port
    bind_port=${bind_port:-8055}

    local rand_token=$(generate_random 16)
    read -p "2. 设置认证 Token [默认: $rand_token]: " token
    token=${token:-$rand_token}

    read -p "3. 仪表盘(面板)端口 [默认: 7500]: " dash_port
    dash_port=${dash_port:-7500}

    read -p "4. 仪表盘用户名 [默认: admin]: " dash_user
    dash_user=${dash_user:-admin}

    local rand_pwd=$(generate_random 12)
    read -p "5. 仪表盘密码 [默认: $rand_pwd]: " dash_pwd
    dash_pwd=${dash_pwd:-$rand_pwd}

    mkdir -p $BASE_DIR
    cat > $BASE_DIR/frps.toml <<EOF
bindPort = $bind_port
auth.token = "$token"

webServer.addr = "0.0.0.0"
webServer.port = $dash_port
webServer.user = "$dash_user"
webServer.password = "$dash_pwd"
EOF
}

# --- 客户端交互配置 ---
config_frpc() {
    echo -e "\n${YELLOW}>>> 开始客户端基础配置${PLAIN}"
    read -p "1. 服务器公网 IP: " s_addr
    until [[ -n "$s_addr" ]]; do
        read -p "${RED}IP不能为空，请重新输入: ${PLAIN}" s_addr
    done

    read -p "2. 服务器监听端口 [默认: 8055]: " s_port
    s_port=${s_port:-8055}

    read -p "3. 服务器 Token: " s_token
    until [[ -n "$s_token" ]]; do
        read -p "${RED}Token不能为空，请重新输入: ${PLAIN}" s_token
    done

    mkdir -p $BASE_DIR
    cat > $BASE_DIR/frpc.toml <<EOF
serverAddr = "$s_addr"
serverPort = $s_port
auth.token = "$s_token"
EOF
}

# --- 具体的部署动作 ---
install_frp_system() {
    local type=$1
    get_arch
    echo -e "${YELLOW}正在从 GitHub 下载二进制文件...${PLAIN}"
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
}

install_frp_docker() {
    local type=$1
    local DOCKER_TAG="v${FRP_VERSION_NUM}"
    check_docker
    echo -e "${YELLOW}正在拉取 Docker 镜像: fatedier/$type:$DOCKER_TAG ...${PLAIN}"
    if ! docker pull fatedier/$type:$DOCKER_TAG; then
        echo -e "${RED}拉取失败，尝试使用 backup 镜像源...${PLAIN}"
    fi
    docker rm -f $type &>/dev/null
    docker run -d --name $type --restart always --network host \
        -v $BASE_DIR/${type}.toml:/etc/frp/${type}.toml fatedier/$type:$DOCKER_TAG
}

# --- 客户端应用管理 ---
manage_apps() {
    if [[ ! -f "$BASE_DIR/frpc.toml" ]]; then
        echo -e "${RED}错误：未发现客户端配置，请先执行安装步骤 3 或 4！${PLAIN}"
        return
    fi

    echo -e "\n1. 添加应用服务 (Add Proxy)"
    echo -e "2. 查看当前配置文件"
    read -p "请选择 [默认: 1]: " app_choice
    app_choice=${app_choice:-1}

    if [ "$app_choice" == "1" ]; then
        echo -e "\n${YELLOW}>>> 添加新的转发规则${PLAIN}"
        read -p "1. 应用名称 (如 ssh/web): " name
        read -p "2. 转发类型 [默认: tcp]: " type
        type=${type:-tcp}
        read -p "3. 本地 IP [默认: 127.0.0.1]: " l_ip
        l_ip=${l_ip:-127.0.0.1}
        read -p "4. 内网端口: " l_port
        read -p "5. 外网访问端口: " r_port

        cat >> $BASE_DIR/frpc.toml <<EOF

[[proxies]]
name = "$name"
type = "$type"
localIP = "$l_ip"
localPort = $l_port
remotePort = $r_port
EOF
        if docker ps | grep -q frpc; then docker restart frpc; else systemctl restart frpc; fi
        echo -e "${GREEN}应用 [$name] 已成功添加并生效！${PLAIN}"
    else
        echo -e "${CYAN}--- 当前配置内容 ---${PLAIN}"
        cat $BASE_DIR/frpc.toml
    fi
}

# --- 主菜单 ---
clear
echo -e "${GREEN}frp 全能版交互式脚本 (系统原生+Docker)${PLAIN}"
echo "----------------------------------------"
echo "1. 安装服务端 (frps) - 系统原生"
echo "2. 安装服务端 (frps) - Docker 容器"
echo "3. 安装/修改客户端 (frpc) - 系统原生"
echo "4. 安装/修改客户端
