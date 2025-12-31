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

# 检查 root 权限
[[ $EUID -ne 0 ]] && echo -e "${RED}错误：必须使用 root 运行！${PLAIN}" && exit 1

# --- 1. 环境预检 (参考你提供的脚本逻辑) ---
pre_install_packs(){
    echo -e "${YELLOW}正在检查必要支持包...${PLAIN}"
    if [ -f /etc/redhat-release ]; then
        yum install -y wget psmisc net-tools curl grep
    else
        apt-get update && apt-get install -y wget psmisc net-tools curl grep
    fi
}

get_public_ip() {
    # 强制获取纯净 IPv4
    local ip=$(curl -s -4 --connect-timeout 5 https://api64.ipify.org | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}')
    [[ -z "$ip" ]] && ip=$(curl -s -4 --connect-timeout 5 ifconfig.me | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}')
    echo "$ip"
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

# --- 2. 核心配置逻辑 (交互界面) ---
config_frps() {
    echo -e "\n${YELLOW}>>> 服务端交互配置 (IPv4)${PLAIN}"
    local detected_ip=$(get_public_ip)
    [[ -z "$detected_ip" ]] && detected_ip="0.0.0.0"

    echo -e "检测到服务器公网 IPv4: ${CYAN}${detected_ip}${PLAIN}"
    read -p "1. 监听地址 [默认: $detected_ip]: " bind_addr
    bind_addr=${bind_addr:-$detected_ip}

    read -p "2. 服务绑定端口 [默认: 8055]: " bind_port
    bind_port=${bind_port:-8055}

    local rand_token=$(generate_random 16)
    read -p "3. 认证 Token [默认: $rand_token]: " token
    token=${token:-$rand_token}

    read -p "4. 面板(Dashboard)端口 [默认: 7500]: " dash_port
    dash_port=${dash_port:-7500}

    read -p "5. 面板用户名 [默认: admin]: " dash_user
    dash_user=${dash_user:-admin}

    local rand_pwd=$(generate_random 12)
    read -p "6. 面板密码 [默认: $rand_pwd]: " dash_pwd
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

# --- 3. 结果面板 (解决返回结果显示) ---
show_frps_info() {
    echo -e "\n${GREEN}==============================================${PLAIN}"
    echo -e "${GREEN}          frps 服务端部署/更新成功！          ${PLAIN}"
    echo -e "${GREEN}==============================================${PLAIN}"
    echo -e "${YELLOW}【客户端连接信息】${PLAIN}"
    echo -e "服务器地址   : ${CYAN}${bind_addr}${PLAIN}"
    echo -e "服务端口     : ${CYAN}${bind_port}${PLAIN}"
    echo -e "认证 Token   : ${CYAN}${token}${PLAIN}"
    echo -e "----------------------------------------------"
    echo -e "${YELLOW}【仪表盘管理后台】${PLAIN}"
    echo -e "访问地址     : ${CYAN}http://${bind_addr}:${dash_port}${PLAIN}"
    echo -e "管理用户     : ${CYAN}${dash_user}${PLAIN}"
    echo -e "管理密码     : ${CYAN}${dash_pwd}${PLAIN}"
    echo -e "${GREEN}==============================================${PLAIN}"
    echo -e "${YELLOW}提示：请确保防火墙已放行端口 ${bind_port} 和 ${dash_port}${PLAIN}\n"
}

# --- 4. 部署动作 (修复 Docker 无法读取配置问题) ---
install_frp_docker() {
    local type=$1
    local DOCKER_TAG="v${FRP_VERSION_NUM}"
    
    if ! command -v docker &> /dev/null; then
        echo -e "${YELLOW}正在安装 Docker 环境...${PLAIN}"
        curl -fsSL https://get.docker.com | bash -s docker
        systemctl start docker && systemctl enable docker
    fi

    echo -e "${YELLOW}正在拉取镜像 fatedier/$type:$DOCKER_TAG ...${PLAIN}"
    docker pull fatedier/$type:$DOCKER_TAG
    docker rm -f $type &>/dev/null

    echo -e "${YELLOW}正在启动 $type 容器...${PLAIN}"
    # 强制指定 -c 路径，解决面板打不开的问题
    docker run -d \
        --name $type \
        --restart always \
        --network host \
        -v $BASE_DIR/${type}.toml:/etc/frp/${type}.toml \
        fatedier/$type:$DOCKER_TAG \
        $type -c /etc/frp/${type}.toml

    sleep 3
    if docker ps | grep -q $type; then
        if [ "$type" == "frps" ]; then show_frps_info; fi
    else
        echo -e "${RED}启动失败，请运行 'docker logs $type' 查看原因。${PLAIN}"
    fi
}

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

# --- 5. 客户端配置与应用管理 ---
config_frpc() {
    echo -e "\n${YELLOW}>>> 客户端连接配置${PLAIN}"
    read -p "1. 服务器公网 IPv4: " s_addr
    until [[ -n "$s_addr" ]]; do read -p "不能为空: " s_addr; done
    read -p "2. 服务器端口 [默认: 8055]: " s_port
    s_port=${s_port:-8055}
    read -p "3. 服务器 Token: " s_token
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
    echo -e "\n${YELLOW}>>> 添加转发规则${PLAIN}"
    read -p "1. 应用名: " name
    read -p "2. 转发类型 [默认: tcp]: " type
    type=${type:-tcp}
    read -p "3. 本地 IP [默认: 127.0.0.1]: " l_ip
    l_ip=${l_ip:-127.0.0.1}
    read -p "4. 本地端口: " l_port
    read -p "5. 远程映射端口: " r_port

    cat >> $BASE_DIR/frpc.toml <<EOF

[[proxies]]
name = "$name"
type = "$type"
localIP = "$l_ip"
localPort = $l_port
remotePort = $r_port
EOF
    if docker ps | grep -q frpc; then docker restart frpc; else systemctl restart frpc; fi
    echo -e "${GREEN}应用 [$name] 已添加并重启。${PLAIN}"
}

# --- 主菜单 ---
clear
pre_install_packs
echo -e "${GREEN}frp 极速全能版脚本 (Docker/原生双模)${PLAIN}"
echo "----------------------------------------"
echo "1. 安装服务端 (frps) - 系统原生"
echo "2. 安装服务端 (frps) - Docker 模式"
echo "3. 安装客户端 (frpc) - 系统原生"
echo "4. 安装客户端 (frpc) - Docker 模式"
echo "5. 客户端应用管理 (添加转发规则)"
echo "6. 彻底卸载 frp"
echo "0. 退出"
read -p "请选择: " main_opt

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
        echo "清理完成。";;
    *) exit 0 ;;
esac
