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
    # 获取用于显示的公网IP
    local ip=$(curl -s -4 https://api64.ipify.org || curl -s -4 ifconfig.me || curl -s -4 ip.sb)
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
    # 如果用户监听的是 0.0.0.0，则获取公网IP显示，否则显示用户自定义的监听地址
    local display_ip=$bind_addr
    if [[ "$bind_addr" == "0.0.0.0" ]]; then
        display_ip=$(get_public_ip)
    fi

    echo -e "\n${GREEN}==============================================${PLAIN}"
    echo -e "${GREEN}          frps 服务端部署/更新成功！          ${PLAIN}"
    echo -e "${GREEN}==============================================${PLAIN}"
    echo -e "${YELLOW}【客户端连接参考信息】${PLAIN}"
    echo -e "服务器地址   : ${CYAN}${display_ip}${PLAIN}"
    echo -e "服务端口     : ${CYAN}${bind_port}${PLAIN}"
    echo -e "认证 Token   : ${CYAN}${token}${PLAIN}"
    echo -e "----------------------------------------------"
    echo -e "${YELLOW}【仪表盘管理后台】${PLAIN}"
    echo -e "访问地址     : ${CYAN}http://${display_ip}:${dash_port}${PLAIN}"
    echo -e "管理用户     : ${CYAN}${dash_user}${PLAIN}"
    echo -e "管理密码     : ${CYAN}${dash_pwd}${PLAIN}"
    echo -e "${GREEN}==============================================${PLAIN}"
    echo -e "${YELLOW}提醒：请在云平台防火墙放行 TCP 端口: ${bind_port}, ${dash_port}${PLAIN}\n"
}

# --- 服务端交互配置 ---
config_frps() {
    echo -e "\n${YELLOW}>>> 开始服务端配置 (IPv4 优先)${PLAIN}"
    
    read -p "1. 监听地址 (IPv4) [默认: 0.0.0.0]: " bind_addr
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
}

# --- 客户端交互配置 ---
config_frpc() {
    echo -e "\n${YELLOW}>>> 开始客户端基础配置${PLAIN}"
    read -p "1. 服务器公网 IP (IPv4): " s_addr
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
    
    # 注意：Docker部署依然建议 host 网络以保证 IPv4 端口透传
    docker run -d --name $type --restart always --network host \
        -v $BASE_DIR/${type}.toml:/etc/frp/${type}.toml fatedier/$type:$DOCKER_TAG
    
    if [ "$type" == "frps" ]; then
        sleep 2
        show_frps_info
    fi
}

# --- 客户端应用管理 ---
manage_apps() {
    if [[ ! -f "$BASE_DIR/frpc.toml" ]]; then
        echo -e "${RED}错误：请先安装客户端！${PLAIN}"
        return
    fi
    echo -e "\n${YELLOW}>>> 添加转发应用${PLAIN}"
    read -p "1. 应用名 (如 web): " name
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
    echo -e "${GREEN}应用 [$name] 已添加并生效！${PLAIN}"
}

# --- 主菜单 ---
clear
echo -e "${GREEN}frp 全能版交互脚本 (强制 IPv4 优先)${PLAIN}"
echo "----------------------------------------"
echo "1. 安装服务端 (frps) - 系统原生"
echo "2. 安装服务端 (frps) - Docker 容器"
echo "3. 安装/修改客户端 (frpc) - 系统原生"
echo "4. 安装/修改客户端 (frpc) - Docker 容器"
echo "5. 客户端应用管理 (添加转发规则)"
echo "6. 彻底卸载 frp"
echo "0. 退出脚本"
read -p "请输入数字选项: " main_opt

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
