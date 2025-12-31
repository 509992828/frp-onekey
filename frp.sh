#!/bin/bash

# 颜色定义
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

# --- 基础变量配置 ---
FRP_VERSION_NUM="0.65.0" 
BASE_DIR="/etc/frp"
BIN_DIR="/usr/local/bin"

# 检查权限
[[ $EUID -ne 0 ]] && echo -e "${RED}错误：必须使用 root 运行！${PLAIN}" && exit 1

# --- 工具函数 ---
get_public_ip() {
    # 强制获取纯净的 IPv4 地址，用于最后的结果展示
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

generate_random() {
    cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w $1 | head -n 1
}

# --- 结果展示面板 ---
show_frps_info() {
    local display_ip=$(get_public_ip)
    echo -e "\n${GREEN}==============================================${PLAIN}"
    echo -e "${GREEN}          frps 服务端部署成功！               ${PLAIN}"
    echo -e "${GREEN}==============================================${PLAIN}"
    echo -e "${YELLOW}【客户端连接信息 - 配置 frpc 时使用】${PLAIN}"
    echo -e "服务器公网 IP : ${CYAN}${display_ip}${PLAIN}"
    echo -e "服务绑定端口  : ${CYAN}${bind_port}${PLAIN}"
    echo -e "认证 Token    : ${CYAN}${token}${PLAIN}"
    echo -e "----------------------------------------------"
    echo -e "${YELLOW}【仪表盘管理后台】${PLAIN}"
    echo -e "访问地址      : ${CYAN}http://${display_ip}:${dash_port}${PLAIN}"
    echo -e "管理用户      : ${CYAN}${dash_user}${PLAIN}"
    echo -e "管理密码      : ${CYAN}${dash_pwd}${PLAIN}"
    echo -e "${GREEN}==============================================${PLAIN}"
    echo -e "${RED}重要：${PLAIN}如果打不开页面，请务必在云平台安全组放行 TCP 端口: ${CYAN}${dash_port}${PLAIN}\n"
}

# --- 服务端交互配置 ---
config_frps() {
    echo -e "\n${YELLOW}>>> 服务端交互配置 (IPv4)${PLAIN}"
    local detected_ip=$(get_public_ip)
    
    # 强制引导用户使用 0.0.0.0
    echo -e "检测到公网 IP: ${CYAN}${detected_ip}${PLAIN}"
    read -p "1. 监听地址 (建议 0.0.0.0) [默认: 0.0.0.0]: " bind_addr
    bind_addr=${bind_addr:-0.0.0.0}

    read -p "2. 绑定服务端口 [默认: 8055]: " bind_port
    bind_port=${bind_port:-8055}

    local rand_token=$(generate_random 16)
    read -p "3. 认证 Token [回车随机]: " token
    token=${token:-$rand_token}

    read -p "4. 面板端口 [默认: 7500]: " dash_port
    dash_port=${dash_port:-7500}

    read -p "5. 面板用户 [默认: admin]: " dash_user
    dash_user=${dash_user:-admin}

    local rand_pwd=$(generate_random 12)
    read -p "6. 面板密码 [回车随机]: " dash_pwd
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

# --- 部署动作 ---
install_frp_docker() {
    local type=$1
    local TAG="v${FRP_VERSION_NUM}"
    check_docker
    docker pull fatedier/$type:$TAG
    docker rm -f $type &>/dev/null

    echo -e "${YELLOW}正在启动 $type 容器...${PLAIN}"
    # 关键修复：添加 -c 参数强制读取挂载的配置文件
    docker run -d \
        --name $type \
        --restart always \
        --network host \
        -v $BASE_DIR/${type}.toml:/etc/frp/${type}.toml \
        fatedier/$type:$TAG \
        -c /etc/frp/${type}.toml

    sleep 3
    if docker ps | grep -q $type; then
        if [ "$type" == "frps" ]; then show_frps_info; fi
    else
        echo -e "${RED}启动失败！请运行 'docker logs $type' 查看原因。${PLAIN}"
    fi
}

# --- 客户端应用管理 ---
manage_apps() {
    if [[ ! -f "$BASE_DIR/frpc.toml" ]]; then echo "请先安装客户端！"; return; fi
    echo -e "\n${YELLOW}>>> 添加转发规则${PLAIN}"
    read -p "1. 应用名 (如 web): " name
    read -p "2. 转发类型 [默认: tcp]: " type
    type=${type:-tcp}
    read -p "3. 内网 IP [默认: 127.0.0.1]: " l_ip
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
    if docker ps | grep -q frpc; then docker restart frpc; fi
    echo -e "${GREEN}应用 [$name] 已添加！${PLAIN}"
}

# --- 菜单及逻辑引导 ---
# (此处省略部分 config_frpc 和 install_frp_system 逻辑，保持之前一致即可)

clear
echo -e "${GREEN}frp 全能版交互脚本${PLAIN}"
echo "----------------------------------------"
echo "1. 安装服务端 (frps) - 系统原生"
echo "2. 安装服务端 (frps) - Docker 容器"
echo "3. 安装客户端 (frpc) - 系统原生"
echo "4. 安装客户端 (frpc) - Docker 容器"
echo "5. 客户端应用管理 (添加规则)"
echo "6. 彻底卸载 frp"
echo "0. 退出脚本"
read -p "请输入选项: " main_opt

case $main_opt in
    2) config_frps && install_frp_docker frps ;;
    6) 
       docker rm -f frps frpc &>/dev/null
       rm -rf $BASE_DIR
       echo "已清理";;
    *) echo "请根据需要补全其他选项逻辑" ;;
esac
