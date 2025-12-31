#!/bin/bash

# 颜色
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

FRP_VERSION_NUM="0.61.0" 
BASE_DIR="/etc/frp"

[[ $EUID -ne 0 ]] && echo -e "${RED}错误：请使用 root 运行！${PLAIN}" && exit 1

# 获取公网IP
get_public_ip() {
    local ip=$(curl -s -4 --connect-timeout 5 https://api64.ipify.org | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}')
    [[ -z "$ip" ]] && ip=$(curl -s -4 --connect-timeout 5 ifconfig.me | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}')
    echo "$ip"
}

# 服务端配置
config_frps() {
    echo -e "\n${YELLOW}>>> 服务端交互配置${PLAIN}"
    pub_ip=$(get_public_ip)
    
    # 【注意】这里强制默认 0.0.0.0，不要改成公网IP，否则 Docker 无法绑定网卡
    read -p "1. 监听地址 [默认: 0.0.0.0]: " bind_addr
    bind_addr=${bind_addr:-0.0.0.0}

    read -p "2. 绑定端口 [默认: 8055]: " bind_port
    bind_port=${bind_port:-8055}

    local r_token=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1)
    read -p "3. 认证 Token [默认: $r_token]: " token
    token=${token:-$r_token}

    read -p "4. 面板端口 [默认: 7500]: " dash_port
    dash_port=${dash_port:-7500}

    read -p "5. 面板用户 [默认: admin]: " dash_user
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

# Docker 安装逻辑
install_frp_docker() {
    local TAG="v${FRP_VERSION_NUM}"
    
    # 检查 Docker
    if ! command -v docker &> /dev/null; then
        curl -fsSL https://get.docker.com | bash -s docker
        systemctl start docker && systemctl enable docker
    fi

    echo -e "${YELLOW}正在启动 frps 容器...${PLAIN}"
    docker rm -f frps &>/dev/null
    
    # 强制执行你手动成功的命令格式
    docker run -d \
        --name frps \
        --restart always \
        --network host \
        -v $BASE_DIR/frps.toml:/etc/frp/frps.toml \
        fatedier/frps:$TAG \
        -c /etc/frp/frps.toml

    echo -e "${YELLOW}正在等待程序启动并检测端口...${PLAIN}"
    sleep 4
    
    if netstat -tunlp | grep -q ":$dash_port "; then
        echo -e "${GREEN}==============================================${PLAIN}"
        echo -e "          frps 服务端成功开启！               "
        echo -e "==============================================${PLAIN}"
        echo -e "访问地址 : ${CYAN}http://${pub_ip}:${dash_port}${PLAIN}"
        echo -e "管理账号 : ${CYAN}${dash_user}${PLAIN} / ${CYAN}${dash_pwd}${PLAIN}"
        echo -e "服务端口 : ${CYAN}${bind_port}${PLAIN}"
        echo -e "认证 Token: ${CYAN}${token}${PLAIN}"
        echo -e "${GREEN}==============================================${PLAIN}"
    else
        echo -e "${RED}错误：端口 $dash_port 未能启动！${PLAIN}"
        echo -e "${YELLOW}以下是容器错误日志：${PLAIN}"
        docker logs frps
    fi
}

# 菜单
menu() {
    clear
    echo -e "${GREEN}frp 一键脚本调试版${PLAIN}"
    echo "1. 安装服务端 (Docker)"
    echo "2. 彻底卸载"
    echo "0. 退出"
    read -p "请选择: " opt
    case $opt in
        1) config_frps && install_frp_docker ;;
        2) docker rm -f frps &>/dev/null; rm -rf $BASE_DIR; echo "清理完成" ;;
        *) exit 0 ;;
    esac
}

# 执行菜单
menu
