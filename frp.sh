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

generate_random() {
    cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w $1 | head -n 1
}

# 服务端配置交互
config_frps() {
    echo -e "\n${YELLOW}>>> 服务端交互配置 (IPv4)${PLAIN}"
    pub_ip=$(get_public_ip)
    echo -e "检测到公网 IP: ${CYAN}${pub_ip}${PLAIN}"
    
    read -p "1. 监听地址 [默认: 0.0.0.0]: " bind_addr
    bind_addr=${bind_addr:-0.0.0.0}

    read -p "2. 绑定端口 [默认: 8055]: " bind_port
    bind_port=${bind_port:-8055}

    # 随机变量定义
    local default_token=$(generate_random 16)
    read -p "3. 认证 Token [默认: $default_token]: " user_token
    token=${user_token:-$default_token}

    read -p "4. 面板端口 [默认: 7500]: " dash_port
    dash_port=${dash_port:-7500}

    read -p "5. 面板用户 [默认: admin]: " dash_user
    dash_user=${dash_user:-admin}

    local default_pwd=$(generate_random 12)
    read -p "6. 面板密码 [默认: $default_pwd]: " user_pwd
    dash_pwd=${user_pwd:-$default_pwd}

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
    echo -e "管理账号     : ${CYAN}${dash_user}${PLAIN}"
    echo -e "管理密码     : ${CYAN}${dash_pwd}${PLAIN}"
    echo -e "${GREEN}==============================================${PLAIN}\n"
}

# 部署
install_frp_docker() {
    local type=$1
    local TAG="v${FRP_VERSION_NUM}"
    check_docker
    docker rm -f $type &>/dev/null
    
    echo -e "${YELLOW}正在启动 $type 容器...${PLAIN}"
    docker run -d \
        --name $type \
        --restart always \
        --network host \
        -v $BASE_DIR/${type}.toml:/etc/frp/${type}.toml \
        fatedier/$type:$TAG $type -c /etc/frp/${type}.toml

    sleep 4
    # 增加实时日志检测
    if docker logs $type 2>&1 | grep -q "started successfully"; then
        if [ "$type" == "frps" ]; then show_frps_info; fi
    else
        echo -e "${RED}启动异常！错误日志如下：${PLAIN}"
        docker logs --tail 10 $type
    fi
}

# 菜单
menu() {
    clear
    echo -e "${GREEN}frp 终极全能脚本${PLAIN}"
    echo "----------------------------------------"
    echo "1. 安装服务端 (Docker 模式)"
    echo "2. 安装客户端 (Docker 模式)"
    echo "3. 彻底卸载"
    echo "0. 退出"
    echo "----------------------------------------"
    read -p "请选择: " opt
    case $opt in
        1) config_frps && install_frp_docker frps ;;
        2) echo "客户端开发中..." ;;
        3) docker rm -f frps &>/dev/null; rm -rf $BASE_DIR; echo "卸载完成" ;;
        *) exit 0 ;;
    esac
}

menu
