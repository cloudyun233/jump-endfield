#!/usr/bin/env bash
set -euo pipefail

# 全局变量
SINGBOX_BIN="/usr/local/bin/sing-box"
SINGBOX_CONF_DIR="/usr/local/etc/sing-box"
SINGBOX_CONF_PATH="$SINGBOX_CONF_DIR/config.json"
NFT_CONF="/etc/nftables.conf"

# 颜色
info(){ echo -e "\e[1;34m[信息]\e[0m $*"; }
warn(){ echo -e "\e[1;33m[警告]\e[0m $*"; }
err(){ echo -e "\e[1;31m[错误]\e[0m $*"; }

# 1. 系统检测和依赖检查
check_sys(){
    if [[ -f /etc/redhat-release ]]; then
        RELEASE="centos"
        PM="yum"
    elif cat /etc/issue | grep -q -E -i "debian|ubuntu"; then
        RELEASE="debian"
        PM="apt"
    elif cat /etc/issue | grep -q -E -i "alpine"; then
        RELEASE="alpine"
        PM="apk"
    else
        err "不支持的操作系统"
        exit 1
    fi
}

install_dependencies(){
    info "正在安装依赖..."
    if [[ "$PM" == "apt" ]]; then
        apt update && apt install -y curl wget jq nftables openssl tar cron
    elif [[ "$PM" == "apk" ]]; then
        apk add curl wget jq nftables openssl tar cronie
        rc-update add crond
        rc-service crond start
    elif [[ "$PM" == "yum" ]]; then
        yum install -y curl wget jq nftables openssl tar cronie
        systemctl enable crond
        systemctl start crond
    fi
}

# 辅助函数：服务管理
create_service_files(){
    if [[ "$RELEASE" == "alpine" ]]; then
        # OpenRC
        cat > "/etc/init.d/sing-box" <<EOF
#!/sbin/openrc-run
name="sing-box"
description="Sing-box Service"
command="$SINGBOX_BIN"
command_args="run -c $SINGBOX_CONF_PATH"
command_background="yes"
pidfile="/run/sing-box.pid"

depend() {
    need net
    after firewall
}
EOF
        chmod +x /etc/init.d/sing-box
        rc-update add sing-box default
    else
        # Systemd
        cat > "/etc/systemd/system/sing-box.service" <<EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
ExecStart=$SINGBOX_BIN run -c $SINGBOX_CONF_PATH
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable sing-box
    fi
}

restart_singbox(){
    if [[ "$RELEASE" == "alpine" ]]; then
        rc-service sing-box restart || rc-service sing-box start
    else
        systemctl restart sing-box
    fi
    info "Sing-box 已重启。"
}

# 2. Sing-box 安装
install_singbox(){
    info "正在安装 Sing-box..."
    # 始终首先尝试官方脚本，但如果失败或需要特定控制，则使用备用方法。
    # 对于此健壮脚本，我们尝试直接二进制安装以确保控制路径和服务文件。
    
    LATEST_VER=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
    if [[ -z "$LATEST_VER" ]]; then
        warn "获取最新版本失败，使用硬编码的备用版本。"
        LATEST_VER="1.12.21" # 备用版本
    fi
    
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) S_ARCH="amd64" ;;
        aarch64) S_ARCH="arm64" ;;
        *) err "不支持的架构: $ARCH"; exit 1 ;;
    esac
    
    URL="https://github.com/SagerNet/sing-box/releases/download/v${LATEST_VER}/sing-box-${LATEST_VER}-linux-${S_ARCH}.tar.gz"
    info "正在下载 Sing-box v$LATEST_VER ($S_ARCH)..."
    wget -O sing-box.tar.gz "$URL"
    tar -zxvf sing-box.tar.gz
    
    # 查找二进制文件（文件夹名称可能不同）
    mv sing-box-*/sing-box "$SINGBOX_BIN"
    rm -rf sing-box*
    chmod +x "$SINGBOX_BIN"

    mkdir -p "$SINGBOX_CONF_DIR"
    if [[ ! -f "$SINGBOX_CONF_PATH" ]]; then
        echo '{"log": {"level": "info", "timestamp": true}, "inbounds": [], "outbounds": [{"type": "direct", "tag": "direct"}]}' > "$SINGBOX_CONF_PATH"
    fi
    
    create_service_files
    info "Sing-box 已安装并配置服务。"
}

# 防火墙辅助函数
# 防火墙辅助函数
open_port(){
    local port="$1"
    local proto="$2" # tcp 或 udp
    
    if command -v firewall-cmd >/dev/null; then
        firewall-cmd --permanent --add-port=${port}/${proto}
        firewall-cmd --reload
    elif command -v nft >/dev/null; then
        # 检查基本输入链是否存在，不存在则创建
        nfthandel=$(nft list table inet singbox_filter 2>/dev/null)
        if [[ -z "$nfthandel" ]]; then
            nft add table inet singbox_filter 2>/dev/null || true
            nft add chain inet singbox_filter input { type filter hook input priority 0 \; policy accept \; } 2>/dev/null || true
        fi
        nft add rule inet singbox_filter input "${proto}" dport "$port" accept 2>/dev/null || true
        nft list ruleset > "$NFT_CONF"
    else
        warn "未找到支持的防火墙管理器 (nftables/firewalld)。请手动打开端口 $port。"
    fi
}

# 端口选择逻辑
get_preferred_port(){
    local protocol="$1" # "hysteria2" or "tuic"
    local other_protocol=""
    [[ "$protocol" == "hysteria2" ]] && other_protocol="tuic" || other_protocol="hysteria2"

    # 检查当前配置
    local current_port_443_proto=$(jq -r '.inbounds[] | select(.listen_port==443) | select(.type != "vless") | .type' "$SINGBOX_CONF_PATH" 2>/dev/null)
    
    if [[ -z "$current_port_443_proto" ]]; then
        # 443 未被使用，直接占用
        echo "443"
        return
    fi

    if [[ "$current_port_443_proto" == "$protocol" ]]; then
        # 443 已经被自己占用了，继续使用
        echo "443"
        return
    fi
    
    # 443 被别人（或 VLESS）占用了，回退到 8443
    echo "8443"
}

configure_forwarding(){
    local hops="$1" # 逗号分隔
    local dest_port="$2"
    local protocol="$3" # "hy2" or "tuic"
    
    IFS=',' read -ra HOP_PORTS <<< "$hops"
    
    if command -v firewall-cmd >/dev/null; then
        info "正在配置 Firewalld 转发 ($protocol)..."
        # Firewalld 通常需要启用伪装
        firewall-cmd --permanent --add-masquerade
        # Firewalld 没有简单的“刷新特定协议规则”的方法，如果不重置所有规则的话。
        # 这里我们假设覆盖是主要目标。
        # 对于 firewalld，add-forward-port 会覆盖相同的端口规则。
        for hop in "${HOP_PORTS[@]}"; do
            firewall-cmd --permanent --add-forward-port=port=${hop}:proto=udp:toport=${dest_port}
            firewall-cmd --permanent --add-port=${hop}/udp
        done
        firewall-cmd --reload
    elif command -v nft >/dev/null; then
        info "正在配置 NFTables 转发 ($protocol)..."
        nft add table inet singbox_nat 2>/dev/null || true
        nft add chain inet singbox_nat prerouting { type nat hook prerouting priority dstnat \; } 2>/dev/null || true
        
        # 创建协议专用链
        local chain_name="singbox_${protocol}"
        nft add chain inet singbox_nat "$chain_name" 2>/dev/null || true
        
        # 确保主链跳转到专用链
        # 检查是否已经有跳转规则，没有则添加
        if ! nft list chain inet singbox_nat prerouting | grep -q "jump $chain_name"; then
            nft add rule inet singbox_nat prerouting jump "$chain_name"
        fi
        
        # 刷新协议专用链
        nft flush chain inet singbox_nat "$chain_name"
        
        # 添加规则到专用链
        nft add rule inet singbox_nat "$chain_name" udp dport { $hops } dnat to :$dest_port
        
        # 确保在过滤器中接受
        open_port "$dest_port" "udp"
        
        nft list ruleset > "$NFT_CONF"
    fi
}

# 3. 辅助函数：生成随机凭证
get_random_uuid(){ uuidgen || cat /proc/sys/kernel/random/uuid; }
get_random_password(){ openssl rand -base64 16; }
get_random_port(){ shuf -i 10000-65000 -n 1; }

# 4. 辅助函数：更新配置 (JQ)
add_inbound(){
    local new_inbound="$1"
    
    # 移除旧的同类型 inbound（如果有）
    local type=$(echo "$new_inbound" | jq -r '.type')
    if [[ -f "$SINGBOX_CONF_PATH" ]]; then
        jq --arg type "$type" 'del(.inbounds[] | select(.type == $type))' "$SINGBOX_CONF_PATH" > "${SINGBOX_CONF_PATH}.tmp" && mv "${SINGBOX_CONF_PATH}.tmp" "$SINGBOX_CONF_PATH"
    fi

    # 添加入站
    jq --argjson new "$new_inbound" '.inbounds += [$new]' "$SINGBOX_CONF_PATH" > "${SINGBOX_CONF_PATH}.tmp" && mv "${SINGBOX_CONF_PATH}.tmp" "$SINGBOX_CONF_PATH"
    restart_singbox
}

# 配置函数
config_vless(){
    info "正在配置 VLESS Reality..."
    local port=443
    
    open_port "$port" "tcp"

    local dest_domain="www.cho-kaguyahime.com"
    local uuid=$(get_random_uuid)
    local short_id=$(openssl rand -hex 4)
    local keys=$("$SINGBOX_BIN" generate reality-keypair)
    local private_key=$(echo "$keys" | grep "PrivateKey" | cut -d: -f2 | tr -d ' \\"')
    local public_key=$(echo "$keys" | grep "PublicKey" | cut -d: -f2 | tr -d ' \\"')

    local inbound=$(jq -n --arg port "$port" --arg uuid "$uuid" --arg dest "$dest_domain" --arg pk "$private_key" --arg sid "$short_id" \
        '{type: "vless", tag: "vless-reality", listen: "::", listen_port: ($port|tonumber), network: "tcp", users: [{uuid: $uuid, flow: "xtls-rprx-vision"}], tls: {enabled: true, server_name: $dest, reality: {enabled: true, handshake: {server: $dest, server_port: 443}, private_key: $pk, short_id: [$sid]}}}')

    add_inbound "$inbound"
    info "VLESS Reality 已配置完成。"
    echo "UUID: $uuid"
    echo "公钥: $public_key"
    echo "短 ID: $short_id"
    echo "端口: $port"
}

config_hy2(){
    info "正在配置 Hysteria2..."
    local port=$(get_preferred_port "hysteria2")
    info "自动选择端口: $port"
    
    open_port "$port" "udp"
    
    local password=$(get_random_password)

    echo "证书模式:"
    echo "1. 自签名"
    echo "2. ACME (需要域名)"
    read -rp "选择 [1]: " cert_mode
    local tls_config=""
    
    if [[ "$cert_mode" == "2" ]]; then
        read -rp "域名: " domain
        read -rp "邮箱: " email
        tls_config=$(jq -n --arg domain "$domain" --arg email "$email" '{enabled: true, server_name: $domain, acme: {domain: [$domain], email: $email}}')
    else
        local cert_path="$SINGBOX_CONF_DIR/hy2_self.crt"
        local key_path="$SINGBOX_CONF_DIR/hy2_self.key"
        openssl req -x509 -newkey rsa:2048 -nodes -sha256 -keyout "$key_path" -out "$cert_path" -days 3650 -subj "/CN=www.cho-kaguyahime.com" 2>/dev/null
        tls_config=$(jq -n --arg cert "$cert_path" --arg key "$key_path" '{enabled: true, certificate_path: $cert, key_path: $key}')
    fi

    read -rp "启用端口跳变? [Y/n]: " hop_choice
    if [[ ! "$hop_choice" =~ ^[Nn]$ ]]; then
        local default_hops="2053,2083,2087,2096,8443"
        read -rp "跳变端口 [$default_hops]: " hops
        hops=${hops:-$default_hops}
        configure_forwarding "$hops" "$port" "hy2"
    fi

    local inbound=$(jq -n --arg port "$port" --arg pass "$password" --argjson tls "$tls_config" \
        '{type: "hysteria2", tag: "hysteria2-in", listen: "::", listen_port: ($port|tonumber), network: "udp", users: [{password: $pass}], tls: $tls}')

    add_inbound "$inbound"
    info "Hysteria2 已配置完成。"
    echo "密码: $password"
    echo "端口: $port"
}

config_tuic(){
    info "正在配置 TUIC v5..."
    local port=$(get_preferred_port "tuic")
    info "自动选择端口: $port"
    
    open_port "$port" "udp"
    
    local uuid=$(get_random_uuid)
    local password=$(get_random_password)

    echo "证书模式:"
    echo "1. 自签名"
    echo "2. ACME (需要域名)"
    read -rp "选择 [1]: " cert_mode
    local tls_config=""
    if [[ "$cert_mode" == "2" ]]; then
        read -rp "域名: " domain
        read -rp "邮箱: " email
        tls_config=$(jq -n --arg domain "$domain" --arg email "$email" '{enabled: true, server_name: $domain, acme: {domain: [$domain], email: $email}}')
    else
        local cert_path="$SINGBOX_CONF_DIR/tuic_self.crt"
        local key_path="$SINGBOX_CONF_DIR/tuic_self.key"
        openssl req -x509 -newkey rsa:2048 -nodes -sha256 -keyout "$key_path" -out "$cert_path" -days 3650 -subj "/CN=www.cho-kaguyahime.com" 2>/dev/null
        tls_config=$(jq -n --arg cert "$cert_path" --arg key "$key_path" '{enabled: true, certificate_path: $cert, key_path: $key}')
    fi
    
    # TUIC 端口跳变
    read -rp "为 TUIC 启用端口跳变? [Y/n]: " hop_choice
    if [[ ! "$hop_choice" =~ ^[Nn]$ ]]; then
        local default_hops="3053,3083,3087"
        read -rp "跳变端口 [$default_hops]: " hops
        hops=${hops:-$default_hops}
        configure_forwarding "$hops" "$port" "tuic"
    fi

    local inbound=$(jq -n --arg port "$port" --arg uuid "$uuid" --arg pass "$password" --argjson tls "$tls_config" \
        '{type: "tuic", tag: "tuic-in", listen: "::", listen_port: ($port|tonumber), network: "udp", users: [{uuid: $uuid, password: $pass}], congestion_control: "bbr", tls: $tls}')

    add_inbound "$inbound"
    info "TUIC v5 已配置完成。"
    echo "UUID: $uuid"
    echo "密码: $password"
    echo "端口: $port"
}

clear_config(){ 
    echo '{"log": {"level": "info", "timestamp": true}, "inbounds": [], "outbounds": [{"type": "direct", "tag": "direct"}]}' > "$SINGBOX_CONF_PATH"
    if command -v nft >/dev/null; then
        nft flush table inet singbox_nat 2>/dev/null || true
    fi
    restart_singbox
    info "配置已清除。"
}

run_test_script(){ bash <(curl -fsSL https://github.com/xykt/ScriptMenu); }
run_bbr(){ bash <(curl -fsSL https://github.com/byJoey/Actions-bbr-v3); }
uninstall_singbox(){ 
    rm -rf "$SINGBOX_BIN" "$SINGBOX_CONF_DIR"
    if [[ "$RELEASE" == "alpine" ]]; then
        rc-service sing-box stop
        rc-update del sing-box
        rm /etc/init.d/sing-box
    else
        systemctl disable --now sing-box
        rm /etc/systemd/system/sing-box.service
        systemctl daemon-reload
    fi
    info "已卸载。"
}

configure_cron_reboot(){
    info "正在配置每天 20:00 UTC 重启。"
    # 检查是否存在
    crontab -l | grep -v "/sbin/reboot" > mycron
    echo "0 20 * * * /sbin/reboot" >> mycron
    crontab mycron
    rm mycron
    info "定时任务已添加。"
}

show_menu(){
    echo "=================================="
    echo "        Sing-box 一键配置          "
    echo "=================================="
    echo "1. 安装 Sing-box"
    echo "2. 配置 VLESS Reality (Vision)"
    echo "3. 配置 Hysteria2"
    echo "4. 配置 TUIC v5"
    echo "5. 清除配置"
    echo "6. 服务器测试 (ScriptMenu)"
    echo "7. 安装 BBR"
    echo "8. 卸载 Sing-box"
    echo "9. 自动重启 (20:00 UTC)"
    echo "0. 退出"
    read -rp "选择: " choice
    case $choice in
        1) install_dependencies; install_singbox ;;
        2) config_vless ;;
        3) config_hy2 ;;
        4) config_tuic ;;
        5) clear_config ;;
        6) run_test_script ;;
        7) run_bbr ;;
        8) uninstall_singbox ;;
        9) configure_cron_reboot ;;
        0) exit 0 ;;
        *) echo "无效选择";;
    esac
}

# 主循环
check_sys
while true; do
    show_menu
    echo
    read -rp "按 Enter 键继续..."
done
