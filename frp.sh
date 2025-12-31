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

# 获取 IPv4
get_public_ip() {
    local ip=$(curl -s -4 --connect-timeout 5 https://api64.ipify.org | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}')
    [[ -z "$ip" ]] && ip=$(curl -s -4 --connect-timeout 5 ifconfig.me | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}')
    echo "$ip"
}

# 交互配置
config_frps() {
    echo -e "\n${YELLOW}>>> 服务端交互配置 (IPv4)${PLAIN}"
    pub_ip=$(get_public_ip)
    [[ -z "$pub_ip" ]] && pub_ip="0.0.0.0"

    echo -e "检测到公网 IP: ${CYAN}${pub_ip}${PLAIN}"
    read -p "1. 监听地址 [默认: 0.0.0.0]: " bind_addr
    bind_addr=${bind_addr:-0.0.0.0}

    read -p "2. 绑定端口 [默认: 8055]: " bind_port
    bind_port=${bind_port:-8055}

    # --- 变量修复区 ---
    local r_token=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1)
    read -p "3. 认证 Token [默认: $r_token]: " user_token
    token=${user_token:-$r_token}

    read -p "4. 面板端口 [默认: 7500]: " dash_port
    dash_port=${dash_port:-7500}

    read -p "5. 面板用户 [默认: admin]: " dash_user
    dash_user=${dash_user:-admin}

    local r_pwd=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 12 | head -n 1)
    read -p "6. 面板密码 [默认: $r_pwd]: " user_pwd
    dash_pwd=${user_pwd:-$r_pwd}
    # ------------------

    mkdir -p $BASE_DIR
    # 生成 TOML
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

# 展示信息
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
    local TAG="v${FRP_VERSION_NUM}"
    
    # 检查 Docker
    if ! command -v docker &> /dev/null; then
        curl -fsSL https://get.docker.com | bash -s docker
        systemctl start docker && systemctl enable docker
    fi

    echo -e "${YELLOW}正在清理旧容器并启动新容器...${PLAIN}"
    docker rm -f frps &>/dev/null
    
    # 这里的 -v 挂载和 -c 参数是成败关键
    docker run -d \
        --name frps \
        --restart always \
        --network host \
        -v $BASE_DIR/frps.toml:/etc/frp/frps.toml \
        fatedier/frps:$TAG \
        -c /etc/frp/frps.toml

    echo -e "${YELLOW}等待程序初始化...${PLAIN}"
    sleep 4
    
    # 验证端口是否真的开启
    if netstat -tunlp | grep -q ":$dash_port "; then
        show_frps_info
    else
        echo -e "${RED}启动失败！面板端口 $dash_port 未被监听。${PLAIN}"
        echo -e "${YELLOW}查看容器日志：${PLAIN}"
        docker logs frps
    fi
}

# 菜单
menu() {
    clear
    echo -e "${GREEN}frp 全能版一键脚本 (修正版)${PLAIN}"
    echo "1. 安装服务端 (Docker)"
    echo "2. 安装客户端 (Docker)"
    echo "3. 彻底卸载"
    echo "0. 退出"
    read -p "选择: " opt
    case $opt in
        1) config_frps && install_frp_docker ;;
        2) echo "客户端功能暂未开启..." ;;
        3) docker rm -f frps &>/dev/null; rm -rf $BASE_DIR; echo "清理完成" ;;
        *) exit 0 ;;
    esac
}

menu
