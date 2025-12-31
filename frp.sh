#!/bin/bash

# 颜色定义
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- 基础变量配置 ---
FRP_VERSION_NUM="0.65.0" 
BASE_DIR="/etc/frp"
BIN_DIR="/usr/local/bin"

# 检查权限
[[ $EUID -ne 0 ]] && echo -e "${RED}错误：必须使用 root 运行！${NC}" && exit 1

# --- 工具函数 ---
get_ip() {
    # 尝试多个接口获取公网IP
    local ip=$(curl -s https://api64.ipify.org || curl -s ifconfig.me || curl -s ip.sb)
    echo "$ip"
}

check_docker() {
    if ! command -v docker &> /dev/null; then
        echo -e "${YELLOW}未检测到 Docker，正在安装...${NC}"
        curl -fsSL https://get.docker.com | bash -s docker
        systemctl start docker && systemctl enable docker
    fi
}

get_arch() {
    arch=$(uname -m)
    case $arch in
        x86_64) arch="amd64" ;;
        aarch64) arch="arm64" ;;
        *) echo -e "${RED}不支持的架构${NC}"; exit 1 ;;
    esac
}

generate_random() {
    cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w $1 | head -n 1
}

# --- 结果展示面板 ---
show_frps_info() {
    local server_ip=$(get_ip)
    echo -e "\n${GREEN}==============================================${NC}"
    echo -e "${GREEN}          frps 服务端部署/更新成功！          ${NC}"
    echo -e "${GREEN}==============================================${NC}"
    echo -e "${YELLOW}【客户端连接信息 - 配置 frpc 时使用】${NC}"
    echo -e "服务器 IP   : ${CYAN}${server_ip}${NC}"
    echo -e "服务端口     : ${CYAN}${bind_port}${NC}"
    echo -e "认证 Token   : ${CYAN}${token}${NC}"
    echo -e "----------------------------------------------"
    echo -e "${YELLOW}【仪表盘管理后台】${NC}"
    echo -e "访问地址     : ${CYAN}http://${server_ip}:${dash_port}${NC}"
    echo -e "管理用户     : ${CYAN}${dash_user}${NC}"
    echo -e "管理密码     : ${CYAN}${dash_pwd}${NC}"
    echo -e "${GREEN}==============================================${NC}"
    echo -e "${YELLOW}提醒：请确保云服务器防火墙/安全组已放行上述端口！${NC}\n"
}

# --- 服务端安装逻辑 (核心配置) ---
config_frps() {
    read -p "绑定端口 [默认 8055]: " bind_port
    bind_port=${bind_port:-8055}
    token=$(generate_random 16)
    read -p "仪表盘端口 [默认 7500]: " dash_port
    dash_port=${dash_port:-7500}
    read -p "仪表盘用户 [默认 admin]: " dash_user
    dash_user=${dash_user:-admin}
    read -p "仪表盘密码 [回车随机]: " dash_pwd
    [[ -z "$dash_pwd" ]] && dash_pwd=$(generate_random 12)

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

# --- 客户端安装逻辑 (核心配置) ---
config_frpc() {
    read -p "服务端 IP: " s_addr
    read -p "服务端 端口: " s_port
    read -p "服务端 Token: " s_token
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
}

install_frp_docker() {
    local type=$1
    local DOCKER_TAG="v${FRP_VERSION_NUM}"
    check_docker
    echo -e "${YELLOW}正在拉取 Docker 镜像: fatedier/$type:$DOCKER_TAG ...${NC}"
    if ! docker pull fatedier/$type:$DOCKER_TAG; then
        echo -e "${RED}错误：拉取镜像失败！${NC}"
        return 1
    fi
    docker rm -f $type &>/dev/null
    docker run -d --name $type --restart always --network host \
        -v $BASE_DIR/${type}.toml:/etc/frp/${type}.toml fatedier/$type:$DOCKER_TAG
}

# --- 客户端应用管理 ---
manage_apps() {
    echo -e "\n1. 添加应用服务\n2. 查看/删除应用(手动编辑)"
    read -p "请选择: " app_choice
    if [ "$app_choice" == "1" ]; then
        read -p "应用名: " name
        read -p "转发类型 [tcp]: " type
        type=${type:-tcp}
        read -p "内网 IP [127.0.0.1]: " l_ip
        l_ip=${l_ip:-127.0.0.1}
        read -p "内网端口: " l_port
        read -p "外网端口: " r_port
        cat >> $BASE_DIR/frpc.toml <<EOF

[[proxies]]
name = "$name"
type = "$type"
localIP = "$l_ip"
localPort = $l_port
remotePort = $r_port
EOF
        if docker ps | grep -q frpc; then docker restart frpc; else systemctl restart frpc; fi
        echo -e "${GREEN}应用已添加并重启生效！${NC}"
    else
        echo -e "${YELLOW}请执行: nano $BASE_DIR/frpc.toml 手动修改${NC}"
    fi
}

# --- 主菜单 ---
clear
echo -e "${GREEN}frp 全能版一键脚本 (系统原生+Docker)${NC}"
echo "--------------------------------"
echo "1. 安装服务端 (frps) - 普通方式"
echo "2. 安装服务端 (frps) - Docker方式"
echo "3. 安装/修改客户端 (frpc) - 普通方式"
echo "4. 安装/修改客户端 (frpc) - Docker方式"
echo "5. 客户端应用管理 (添加转发)"
echo "6. 卸载 frp (清理容器及程序)"
echo "0. 退出"
read -p "请输入选项: " main_opt

case $main_opt in
    1) config_frps && install_frp_system frps && show_frps_info ;;
    2) config_frps && install_frp_docker frps && show_frps_info ;;
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
