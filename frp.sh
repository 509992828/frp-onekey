#!/bin/bash

# 颜色定义
RED='\033[031m'
GREEN='\033[032m'
YELLOW='\033[033m'
PLAIN='\033[0m'

# 检查 root 权限
[[ $EUID -ne 0 ]] && echo -e "${RED}错误：${PLAIN} 必须使用 root 用户运行此脚本！\n" && exit 1

# 变量准备
FRP_VERSION="0.61.0" # 你可以根据需要更新版本
CONF_DIR="/etc/frp"
BIN_DIR="/usr/local/bin"

# 自动获取架构
get_arch() {
    arch=$(uname -m)
    if [[ $arch == "x86_64" ]]; then
        arch="amd64"
    elif [[ $arch == "aarch64" ]]; then
        arch="arm64"
    else
        echo -e "${RED}不支持的架构: $arch${PLAIN}"
        exit 1
    fi
}

# 随机字符串生成
generate_token() {
    cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1
}

# 获取公网IP
get_ip() {
    ip=$(curl -s https://api64.ipify.org || curl -s ifconfig.me)
    echo $ip
}

# 安装二进制文件
install_frp() {
    get_arch
    local type=$1 # frps 或 frpc
    echo -e "${YELLOW}正在下载 frp v${FRP_VERSION}...${PLAIN}"
    wget https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_${FRP_VERSION}_linux_${arch}.tar.gz -O frp.tar.gz
    tar -zxvf frp.tar.gz
    cp frp_${FRP_VERSION}_linux_${arch}/$type $BIN_DIR/
    mkdir -p $CONF_DIR
    rm -rf frp.tar.gz frp_${FRP_VERSION}_linux_${arch}
    echo -e "${GREEN}主程序安装成功！${PLAIN}"
}

# 配置服务端的 systemd
setup_systemd() {
    local type=$1
    cat > /etc/systemd/system/${type}.service <<EOF
[Unit]
Description=frp $type service
After=network.target

[Service]
Type=simple
ExecStart=$BIN_DIR/$type -c $CONF_DIR/${type}.toml
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable $type
    systemctl restart $type
    echo -e "${GREEN}服务已启动并设置开机自启。${PLAIN}"
}

# --- 服务端安装逻辑 ---
install_frps() {
    install_frp frps
    
    echo -e "${YELLOW}--- 服务端配置 ---${PLAIN}"
    read -p "请输入服务监听端口 [默认: 8055]: " bind_port
    bind_port=${bind_port:-8055}
    
    token=$(generate_token)
    echo -e "${GREEN}已自动生成 Token: $token${PLAIN}"
    
    read -p "请输入仪表盘端口 [默认: 7500]: " dash_port
    dash_port=${dash_port:-7500}
    
    read -p "请输入仪表盘用户名 [默认: admin]: " dash_user
    dash_user=${dash_user:-admin}
    
    read -p "请输入仪表盘密码 [不填则随机]: " dash_pwd
    if [[ -z "$dash_pwd" ]]; then
        dash_pwd=$(generate_token)
        echo -e "${GREEN}生成的管理密码: $dash_pwd${PLAIN}"
    fi

    cat > $CONF_DIR/frps.toml <<EOF
bindPort = $bind_port
auth.token = "$token"

webServer.addr = "0.0.0.0"
webServer.port = $dash_port
webServer.user = "$dash_user"
webServer.password = "$dash_pwd"
EOF

    setup_systemd frps
    echo -e "\n${GREEN}frps 安装完成！${PLAIN}"
    echo -e "服务器IP: $(get_ip)"
    echo -e "绑定端口: $bind_port"
    echo -e "Token: $token"
    echo -e "仪表盘地址: http://$(get_ip):$dash_port"
}

# --- 客户端安装/修改逻辑 ---
install_frpc() {
    if [[ ! -f "$BIN_DIR/frpc" ]]; then
        install_frp frpc
    fi
    
    echo -e "${YELLOW}--- 连接设置 ---${PLAIN}"
    read -p "服务端 IP 地址: " server_addr
    read -p "服务端 端口: " server_port
    read -p "服务端 Token: " server_token

    cat > $CONF_DIR/frpc.toml <<EOF
serverAddr = "$server_addr"
serverPort = $server_port
auth.token = "$server_token"
EOF

    setup_systemd frpc
    echo -e "${GREEN}客户端基础配置已保存并启动。${PLAIN}"
}

# --- 客户端应用管理 ---
manage_app() {
    if [[ ! -f "$CONF_DIR/frpc.toml" ]]; then
        echo -e "${RED}请先执行安装客户端！${PLAIN}"
        return
    fi

    echo -e "1. 添加应用服务"
    echo -e "2. 删除应用服务"
    read -p "请选择: " app_choice

    if [[ "$app_choice" == "1" ]]; then
        read -p "应用名称 (例如 web): " app_name
        read -p "转发类型 [默认: tcp]: " app_type
        app_type=${app_type:-tcp}
        read -p "本地 IP [默认: 127.0.0.1]: " local_ip
        local_ip=${local_ip:-127.0.0.1}
        read -p "内网端口: " local_port
        read -p "外网端口: " remote_port

        cat >> $CONF_DIR/frpc.toml <<EOF

[[proxies]]
name = "$app_name"
type = "$app_type"
localIP = "$local_ip"
localPort = $local_port
remotePort = $remote_port
EOF
        systemctl restart frpc
        echo -e "${GREEN}应用 $app_name 添加成功并已重启服务。${PLAIN}"

    elif [[ "$app_choice" == "2" ]]; then
        echo -e "${YELLOW}当前配置文件内容如下：${PLAIN}"
        grep "name =" $CONF_DIR/frpc.toml
        read -p "请输入要删除的应用名称: " del_name
        # 简单处理：使用 sed 删除 proxies 块（在 TOML 中处理块删除较复杂，此处建议手动或备份覆盖）
        echo -e "${RED}提示：删除功能建议手动编辑 $CONF_DIR/frpc.toml 确保准确${PLAIN}"
    fi
}

# --- 主菜单 ---
menu() {
    clear
    echo -e "${GREEN}frp 一键安装管理脚本${PLAIN}"
    echo -e "1. 安装服务端 (frps)"
    echo -e "2. 安装/修改客户端 (frpc)"
    echo -e "3. 客户端应用管理 (添加/删除服务)"
    echo -e "4. 卸载 frp"
    echo -e "0. 退出"
    read -p "请选择: " choice

    case $choice in
        1) install_frps ;;
        2) install_frpc ;;
        3) manage_app ;;
        4)
            systemctl stop frps frpc
            rm -f $BIN_DIR/frps $BIN_DIR/frpc /etc/systemd/system/frp*.service
            rm -rf $CONF_DIR
            echo -e "${GREEN}卸载完成。${PLAIN}"
            ;;
        *) exit 0 ;;
    esac
}

menu
