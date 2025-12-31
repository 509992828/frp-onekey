#!/bin/bash

# 颜色定义
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

# 基础变量
FRP_VERSION="0.65.0"
BASE_DIR="/etc/frp"
BIN_DIR="/usr/local/bin"

# 检查权限
[[ $EUID -ne 0 ]] && echo -e "${RED}错误：必须使用 root 运行！${NC}" && exit 1

# --- 工具函数 ---
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

# --- 服务端安装逻辑 (核心配置) ---
config_frps() {
    read -p "绑定端口 [默认 8055]: " bind_port
    bind_port=${bind_port:-8055}
    token=$(generate_random 16)
    echo -e "自动生成 Token: ${GREEN}$token${NC}"
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
    local type=$1 # frps or frpc
    get_arch
    wget https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_${FRP_VERSION}_linux_${arch}.tar.gz -O frp.tar.gz
    tar -zxvf frp.tar.gz
    cp frp_${FRP_VERSION}_linux_${arch}/$type $BIN_DIR/
    rm -rf frp.tar.gz frp_${FRP_VERSION}_linux_${arch}
    
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

#  定义版本号变量，方便后续统一修改
FRP_VERSION="v0.65.0"
install_frp_docker() {
    local type=$1 # frps 或 frpc
    
    check_docker
    
    echo -e "${YELLOW}正在拉取 Docker 镜像: fatedier/$type:$FRP_TAG ...${NC}"
    
    # 先拉取镜像，如果失败则停止执行
    if ! docker pull fatedier/$type:$FRP_TAG; then
        echo -e "${RED}错误：拉取镜像失败！请检查网络连接或镜像版本是否正确。${NC}"
        return 1
    fi

    echo -e "${GREEN}镜像拉取成功，正在启动容器...${NC}"
    
    # 删除旧容器（如果存在）
    docker rm -f $type &>/dev/null
    
    # 启动新容器
    docker run -d \
        --name $type \
        --restart always \
        --network host \
        -v $BASE_DIR/${type}.toml:/etc/frp/${type}.toml \
        fatedier/$type:$FRP_TAG

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}$type Docker 容器已成功启动！${NC}"
    else
        echo -e "${RED}$type 容器启动失败，请检查 Docker 日志。${NC}"
    fi
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
echo -e "${GREEN}frp 全能版一键脚本 (普通+Docker)${NC}"
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
