#!/bin/bash

# 颜色定义
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

# --- 基础变量 ---
FRP_VERSION_NUM="0.61.0" 
BASE_DIR="/etc/frp"

# --- 强制 IPv4 获取 ---
get_public_ip() {
    local ip=$(curl -s -4 --connect-timeout 5 https://api64.ipify.org | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}')
    [[ -z "$ip" ]] && ip=$(curl -s -4 --connect-timeout 5 ifconfig.me | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}')
    echo "$ip"
}

# --- 服务端交互 ---
config_frps() {
    echo -e "\n${YELLOW}>>> 服务端交互配置${PLAIN}"
    pub_ip=$(get_public_ip)
    
    # 强制建议使用 0.0.0.0 绑定，防止云服务器因 IP 映射导致启动失败
    read -p "1. 监听地址 [建议 0.0.0.0]: " bind_addr
    bind_addr=${bind_addr:-0.0.0.0}

    read -p "2. 绑定端口 [默认 8055]: " bind_port
    bind_port=${bind_port:-8055}

    local r_token=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1)
    read -p "3. 认证 Token [默认: $r_token]: " token
    token=${token:-$r_token}

    read -p "4. 面板端口 [默认 7500]: " dash_port
    dash_port=${dash_port:-7500}

    read -p "5. 面板用户 [默认 admin]: " dash_user
    dash_user=${dash_user:-admin}

    local r_pwd=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 12 | head -n 1)
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

# --- 部署结果面板 ---
show_frps_info() {
    echo -e "\n${GREEN}==============================================${PLAIN}"
    echo -e "${GREEN}          frps 服务端部署成功！               ${PLAIN}"
    echo -e "${GREEN}==============================================${PLAIN}"
    echo -e "${YELLOW}【客户端连接信息】${PLAIN}"
    echo -e "服务器地址   : ${CYAN}${pub_ip}${PLAIN}"
    echo -e "服务端口     : ${CYAN}${bind_port}${PLAIN}"
    echo -e "认证 Token   : ${CYAN}${token}${PLAIN}"
    echo -e "----------------------------------------------"
    echo -e "${YELLOW}【仪表盘管理后台】${PLAIN}"
    echo -e "访问地址     : ${CYAN}http://${pub_ip}:${dash_port}${PLAIN}"
    echo -e "管理用户     : ${CYAN}${dash_user}${PLAIN}"
    echo -e "管理密码     : ${CYAN}${dash_pwd}${PLAIN}"
    echo -e "${GREEN}==============================================${PLAIN}"
    echo -e "${RED}若无法打开面板，请务必去云平台安全组放行端口: ${dash_port}${PLAIN}\n"
}

# --- Docker 启动 ---
install_frp_docker() {
    local type=$1
    local TAG="v${FRP_VERSION_NUM}"
    docker rm -f $type &>/dev/null
    docker pull fatedier/$type:$TAG
    
    # 强制带上 -c 参数并使用绝对路径
    docker run -d \
        --name $type \
        --restart always \
        --network host \
        -v $BASE_DIR/${type}.toml:/etc/frp/${type}.toml \
        fatedier/$type:$TAG \
        $type -c /etc/frp/${type}.toml

    sleep 2
    if [ "$type" == "frps" ]; then show_frps_info; fi
}

# --- 后面是主菜单及其他功能 (保持原样) ---
# ...（略）
