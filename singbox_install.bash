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
    info "正在安装 Sing-box (手动二进制方式)..."
    
    # [新增] 预清理，确保通配符匹配准确
    rm -rf sing-box.tar.gz sing-box-*/

    # 获取版本号
    LATEST_VER=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
    if [[ -z "$LATEST_VER" ]]; then
        warn "获取最新版本失败，使用硬编码的备用版本。"
        LATEST_VER="1.12.21" 
    fi
    
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) S_ARCH="amd64" ;;
        aarch64) S_ARCH="arm64" ;;
        *) err "不支持的架构: $ARCH"; exit 1 ;;
    esac
    
    URL="https://github.com/SagerNet/sing-box/releases/download/v${LATEST_VER}/sing-box-${LATEST_VER}-linux-${S_ARCH}.tar.gz"
    info "正在下载 Sing-box v$LATEST_VER ($S_ARCH)..."
    
    # [优化] 增加下载成功检查
    if ! wget -O sing-box.tar.gz "$URL"; then
        err "下载 Sing-box 失败，请检查网络！"
        exit 1
    fi

    tar -zxvf sing-box.tar.gz
    
    # [优化] 确保目标二进制目录存在
    mkdir -p "$(dirname "$SINGBOX_BIN")"
    
    # 查找并移动二进制文件
    if ls sing-box-*/sing-box >/dev/null 2>&1; then
        mv sing-box-*/sing-box "$SINGBOX_BIN"
        chmod +x "$SINGBOX_BIN"
    else
        err "解压后未找到二进制文件！"
        exit 1
    fi

    # 清理现场
    rm -rf sing-box.tar.gz sing-box-*/

    # 配置处理
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

configure_dnat(){
    local hops="$1"
    local dest_port="$2"

    IFS=',' read -ra HOP_PORTS <<< "$hops"
    
    # 清除现有规则提示
    info "正在清除由于端口跳跃设置的旧防火墙转发规则..."
    
    if command -v firewall-cmd >/dev/null; then
        # Firewalld logic
        # 尝试清除所有转发到 dest_port 的规则 (Best effort)
        # 这是一个简化的清除，实际上 firewalld 很难精确清除未知的转发，除非我们遍历所有端口。
        # 这里我们假设用户使用的是我们默认的端口或者之前的端口。
        # 由于无法确切知道之前的 hops，这里我们发出警告，但执行重载。
        # 为了真正清除，我们需要列出所有 forward-port 并删除。
        
        # 获取所有 forward-ports
        fw_forwards=$(firewall-cmd --list-forward-ports)
        if [[ -n "$fw_forwards" ]]; then
            echo "$fw_forwards" | while read -r rule; do
                # 格式: port=8443:proto=udp:toport=443:toaddr=
                # 我们只关心 toport=$dest_port 的规则，或者是我们之前定义的跳跃端口。
                # 简单起见，我们只能清除完全匹配的，或者提示用户。
                # 鉴于脚本复杂性，这里我们只做添加。如果用户想要清除旧的，建议手动重置 firewalld。
                warn "Firewalld 模式下，自动清除旧的自定义端口转发可能不完全。建议定期检查 firewall-cmd --list-forward-ports"
            done
        fi
        
        # 无论如何，添加新的
        info "正在配置 Firewalld 转发..."
        firewall-cmd --permanent --add-masquerade
        for hop in "${HOP_PORTS[@]}"; do
            # 移除旧的（如果完全匹配）- 尝试移除常见默认值
            firewall-cmd --permanent --remove-forward-port=port=${hop}:proto=udp:toport=${dest_port} 2>/dev/null || true
            
            # 添加新的
            firewall-cmd --permanent --add-forward-port=port=${hop}:proto=udp:toport=${dest_port}
            firewall-cmd --permanent --add-port=${hop}/udp
        done
        firewall-cmd --reload
        info "Firewalld 规则已应用。"

    elif command -v nft >/dev/null; then
        info "正在配置 NFTables 转发..."
        
        # NFTables 容易清除：直接刷新 singbox_nat 表
        # 这会清除所有由本脚本管理的 NAT 规则
        nft flush table inet singbox_nat 2>/dev/null || true
        
        # 重建表和链
        nft add table inet singbox_nat 2>/dev/null || true
        nft add chain inet singbox_nat prerouting { type nat hook prerouting priority dstnat \; } 2>/dev/null || true
        
        local chain_name="singbox_dnat"
        nft add chain inet singbox_nat "$chain_name" 2>/dev/null || true
        
        # 确保跳转
        if ! nft list chain inet singbox_nat prerouting | grep -q "jump $chain_name"; then
            nft add rule inet singbox_nat prerouting jump "$chain_name"
        fi
        
        # 添加规则
        nft add rule inet singbox_nat "$chain_name" udp dport { $hops } dnat to :$dest_port
        
        # 开放端口
        # 注意：这里我们开放所有跳跃端口，使用集合语法
        # 确保 filter 表存在
        nfthandel=$(nft list table inet singbox_filter 2>/dev/null)
        if [[ -z "$nfthandel" ]]; then
            nft add table inet singbox_filter 2>/dev/null || true
            nft add chain inet singbox_filter input { type filter hook input priority 0 \; policy accept \; } 2>/dev/null || true
        fi
        # 允许这些端口 (直接使用 hops 变量，因为它已经包含了逗号分隔列表，适合 nft 集合语法)
        nft add rule inet singbox_filter input udp dport { $hops } accept
        
        nft list ruleset > "$NFT_CONF"
        info "NFTables 规则已更新并保存。"
    fi
}

config_port_hopping(){
    # Firewalld 警告 + 二次确认
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        warn "检测到您使用的是 Firewalld（常见于 CentOS/RHEL 等 RedHat 系系统）。"
        warn "端口跳跃功能在 Firewalld 下有明显限制："
        warn "  • 不支持端口范围（如 2000-3000）"
        warn "  • 旧转发规则难以彻底清除，可能残留"
        warn "强烈建议使用 nftables 系统（如 Debian/Ubuntu/Alpine）以获得完整功能。"
        echo
        read -rp "是否仍要继续配置？[y/N]: " force
        [[ "$force" =~ ^[Yy]$ ]] || { info "已取消操作。"; return; }
    fi

    info "正在配置防火墙转发 (端口跳跃)..."
    
    # 获取目的端口
    local default_dest="443"
    read -rp "请输入目标端口 (即 Hy2/TUIC 实际监听的端口) [默认: $default_dest]: " dest_port
    dest_port=${dest_port:-$default_dest}
    
    # 获取跳跃端口
    local default_hops="443,2053,2083,2087,2096,8443"
    echo "请输入接收端口（多个端口用逗号分隔，支持范围如 2000-3000，但 Firewalld 不支持范围）"
    read -rp "默认 [$default_hops]: " input_ports
    input_ports=${input_ports:-$default_hops}
    
    # 简单去空格，防止 nftables 语法错误（用户输入 443, 2053 这种）
    input_ports="${input_ports// /}"

    # 确认信息
    echo "--------------------------------"
    echo "目标端口: $dest_port"
    echo "跳转端口: $input_ports"
    echo "--------------------------------"
    read -rp "确认配置？这将覆盖现有的端口跳跃规则 [Y/n]: " confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        info "已取消。"
        return
    fi
    
    configure_dnat "$input_ports" "$dest_port"
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

    # 端口跳变逻辑已移除，移至主菜单单独配置

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
    # TUIC 端口跳变逻辑已移除，移至主菜单单独配置

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

run_test_script(){ bash <(curl -Ls Check.Place); }
run_bbr(){ bash <(curl -l -s https://raw.githubusercontent.com/byJoey/Actions-bbr-v3/refs/heads/main/install.sh); }
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
    info "正在检查并配置系统时间为 UTC..."
    
    # 检查当前时区
    current_timezone=$(timedatectl show --property=Timezone --value 2>/dev/null || date +%Z)
    
    if [[ "$current_timezone" != "UTC" ]]; then
        info "当前时区不是 UTC，正在设置为 UTC..."
        if command -v timedatectl &>/dev/null; then
            timedatectl set-timezone UTC
            info "时区已设置为 UTC"
        else
            # 备用方案：手动设置
            if [[ -f /etc/localtime ]]; then
                rm -f /etc/localtime
            fi
            ln -sf /usr/share/zoneinfo/UTC /etc/localtime
            info "时区已设置为 UTC (通过符号链接)"
        fi
    else
        info "当前时区已经是 UTC"
    fi
    
    # 显示当前时间
    info "当前系统时间: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    
    info "正在配置每天 20:00 UTC 重启。"
    # 检查是否存在
    crontab -l 2>/dev/null | grep -v "/sbin/reboot" > mycron || true
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
    echo "5. 配置防火墙转发 (端口跳跃)(redhat系防火墙不建议使用)"
    echo "6. 清除singbox配置"
    echo "7. 卸载 Sing-box"
    echo "8. 服务器相关测试"
    echo "9. 安装 BBR"
    echo "10. 自动重启 (20:00 UTC)"
    echo "0. 退出"
    read -rp "选择: " choice
    case $choice in
        1) install_dependencies; install_singbox ;;
        2) config_vless ;;
        3) config_hy2 ;;
        4) config_tuic ;;
        5) config_port_hopping ;;
        6) clear_config ;;
        7) uninstall_singbox ;;
        8) run_test_script ;;
        9) run_bbr ;;
        10) configure_cron_reboot ;;
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
