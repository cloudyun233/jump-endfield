#!/usr/bin/env bash
# set -euo pipefail

# 全局变量
SINGBOX_BIN="/usr/local/bin/sing-box"
SINGBOX_CONF_DIR="/usr/local/etc/sing-box"
SINGBOX_CONF_PATH="$SINGBOX_CONF_DIR/config.json"
NFT_CONF="/etc/nftables.conf"
DEFAULT_DOMAIN="www.cho-kaguyahime.com"

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
        apt update && apt install -y curl wget jq nftables openssl tar cron || { err "依赖安装失败"; return 1; }
    elif [[ "$PM" == "apk" ]]; then
        apk add curl wget jq nftables openssl tar cronie || { err "依赖安装失败"; return 1; }
        rc-update add crond
        rc-service crond start
    elif [[ "$PM" == "yum" ]]; then
        yum install -y curl wget jq nftables openssl tar cronie || { err "依赖安装失败"; return 1; }
        systemctl enable crond
        systemctl start crond
    fi
}

# 辅助函数：服务管理
create_service_files(){
    if [[ "$RELEASE" == "alpine" ]]; then
        local service_file="/etc/init.d/sing-box"
        if [[ ! -f "$service_file" ]]; then
            info "正在创建 OpenRC 服务文件..."
            cat > "$service_file" <<EOF
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
            chmod +x "$service_file"
            rc-update add sing-box default
            info "OpenRC 服务文件已创建并启用。"
        else
            info "OpenRC 服务文件已存在，跳过创建。"
        fi
    else
        local service_file="/etc/systemd/system/sing-box.service"
        if [[ ! -f "$service_file" ]]; then
            info "正在创建 Systemd 服务文件..."
            cat > "$service_file" <<EOF
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
            info "Systemd 服务文件已创建并启用。"
        else
            info "Systemd 服务文件已存在，跳过创建。"
        fi
    fi
}

restart_singbox(){
    info "正在验证和格式化配置文件..."
    
    # 格式化配置文件
    if "$SINGBOX_BIN" format -w -c "$SINGBOX_CONF_PATH"; then
        info "配置文件已格式化。"
    else
        warn "配置文件格式化失败，可能存在语法错误。"
    fi
    
    # 验证配置文件
    if "$SINGBOX_BIN" check -c "$SINGBOX_CONF_PATH"; then
        info "配置文件验证通过。"
    else
        err "配置文件验证失败，请检查配置！"
        return 1
    fi
    
    info "正在重启 Sing-box 服务..."
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
        *) err "不支持的架构: $ARCH"; return 1 ;;
    esac
    
    URL="https://github.com/SagerNet/sing-box/releases/download/v${LATEST_VER}/sing-box-${LATEST_VER}-linux-${S_ARCH}.tar.gz"
    info "正在下载 Sing-box v$LATEST_VER ($S_ARCH)..."
    
    # [优化] 增加下载成功检查
    if ! wget -O sing-box.tar.gz "$URL"; then
        err "下载 Sing-box 失败，请检查网络！"
        return 1
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
        return 1
    fi

    # 清理现场
    rm -rf sing-box.tar.gz sing-box-*/

    # 配置处理
    mkdir -p "$SINGBOX_CONF_DIR"
    echo '{"log": {"level": "info", "timestamp": true}, "inbounds": [], "outbounds": [{"type": "direct", "tag": "direct"}]}' > "$SINGBOX_CONF_PATH"
    
    create_service_files
    info "Sing-box 已安装并配置服务。"
}

# 防火墙辅助函数
open_port(){
    local port="$1"
    local proto="$2"
    
    if command -v nft >/dev/null; then
        nfthandel=$(nft list table inet singbox_filter 2>/dev/null)
        if [[ -z "$nfthandel" ]]; then
            nft add table inet singbox_filter || true
            nft add chain inet singbox_filter input { type filter hook input priority 0 \; policy accept \; } || true
        fi
        
        if ! nft list table inet singbox_filter 2>/dev/null | grep -q "${proto} dport ${port} accept"; then
            nft add rule inet singbox_filter input "${proto}" dport "$port" accept || true
        fi
        nft list ruleset > "$NFT_CONF"
    else
        warn "未找到 nftables，请手动打开端口 $port。"
    fi
}

# 端口选择逻辑
get_preferred_port(){
    local protocol="$1" # "hysteria2" or "tuic"
    local other_protocol=""
    if [[ "$protocol" == "hysteria2" ]]; then
        other_protocol="tuic"
    else
        other_protocol="hysteria2"
    fi

    # 检查当前配置
    local current_port_443_proto=$(jq -r '.inbounds[] | select(.listen_port==443) | select(.type != "vless") | .type' "$SINGBOX_CONF_PATH" 2>/dev/null || true)
    
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
    
    # 443 被别人占用了，回退到 8443
    echo "8443"
}

configure_dnat(){
    local hops="$1"
    local dest_port="$2"

    info "正在清除由于端口跳跃设置的旧防火墙转发规则..."
    
    info "正在配置 NFTables 转发..."
    
    nft delete table inet singbox_nat 2>/dev/null || true
    
    nft add table inet singbox_nat
    nft add chain inet singbox_nat prerouting { type nat hook prerouting priority dstnat \; policy accept \; }
    nft add rule inet singbox_nat prerouting udp dport \{$hops\} dnat to :$dest_port
    
    nft list ruleset > "$NFT_CONF"
    
    if [[ "$RELEASE" == "alpine" ]]; then
        rc-service nftables restart
    else
        systemctl restart nftables
    fi
    info "NFTables 规则已更新并生效。"
}

config_port_hopping(){
    if ! command -v nft >/dev/null 2>&1; then
        err "端口跳跃功能需要 nftables 支持。"
        err "当前系统未安装 nftables，请先安装后重试。"
        err "Debian/Ubuntu: apt install nftables"
        err "Alpine: apk add nftables"
        return 1
    fi

    info "正在配置防火墙转发 (端口跳跃)..."
    
    local default_dest="443"
    read -rp "请输入目标端口 (即 Hy2/TUIC 实际监听的端口) [默认: $default_dest]: " dest_port
    dest_port=${dest_port:-$default_dest}
    
    local default_hops="443,2053,2083,2087,2096,8443,9443"
    echo "请输入接收端口（多个端口用逗号分隔，支持范围如 2000-3000）"
    read -rp "默认 [$default_hops]: " input_ports
    input_ports=${input_ports:-$default_hops}
    
    input_ports="${input_ports// /}"

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

# 辅助函数：清理证书文件
cleanup_cert_files(){
    local cert_path="$SINGBOX_CONF_DIR/singbox.crt"
    local key_path="$SINGBOX_CONF_DIR/singbox.key"
    
    if [[ -f "$cert_path" ]] || [[ -f "$key_path" ]]; then
        info "检测到已存在的证书文件，正在清理..."
        rm -f "$cert_path" "$key_path"
        info "旧证书文件已清理。"
    fi
}

# 辅助函数：生成 TLS 配置
generate_tls_config(){
    echo "证书模式:" >&2
    echo "1. 自签名(需要允许不安全)" >&2
    echo "2. ACME (需要域名)" >&2
    read -erp "选择 [1]: " TLS_CERT_MODE
    
    if [[ "$TLS_CERT_MODE" == "2" ]]; then
        read -erp "域名: " domain
        read -erp "邮箱: " email
        jq -n --arg domain "$domain" --arg email "$email" --arg data_dir "$SINGBOX_CONF_DIR" '
            {
                enabled: true,
                alpn: ["h3"],
                server_name: $domain,
                acme: {
                    domain: [$domain],
                    email: $email,
                    data_directory: $data_dir
                }
            }
        '
    else
        local cert_path="$SINGBOX_CONF_DIR/singbox.crt"
        local key_path="$SINGBOX_CONF_DIR/singbox.key"
        
        cleanup_cert_files
        
        openssl req -x509 -newkey rsa:2048 -nodes -sha256 -keyout "$key_path" -out "$cert_path" -days 3650 -subj "/CN=$DEFAULT_DOMAIN" || true
        jq -n --arg cert "$cert_path" --arg key "$key_path" '
            {
                enabled: true,
                alpn: ["h3"],
                certificate_path: $cert,
                key_path: $key
            }
        '
    fi
}

# 辅助函数：更新配置 (JQ)
add_inbound(){    local new_inbound="$1"
    
    # 确保配置目录存在
    mkdir -p "$SINGBOX_CONF_DIR"
    
    # 确保配置文件存在
    if [[ ! -f "$SINGBOX_CONF_PATH" ]]; then
        echo '{"log": {"level": "info", "timestamp": true}, "inbounds": [], "outbounds": [{"type": "direct", "tag": "direct"}]}' > "$SINGBOX_CONF_PATH"
    fi
    
    # 移除旧的同类型 inbound（如果有）
    local type=$(echo "$new_inbound" | jq -r '.type' || true)
    jq --arg type "$type" 'del(.inbounds[]? | select(.type == $type))' "$SINGBOX_CONF_PATH" > "${SINGBOX_CONF_PATH}.tmp" && mv "${SINGBOX_CONF_PATH}.tmp" "$SINGBOX_CONF_PATH" || true

    # 添加入站
    if jq --argjson new "$new_inbound" '.inbounds += [$new]' "$SINGBOX_CONF_PATH" > "${SINGBOX_CONF_PATH}.tmp"; then
        mv "${SINGBOX_CONF_PATH}.tmp" "$SINGBOX_CONF_PATH"
    else
        err "添加配置失败 (jq error)"
        return 1
    fi
    restart_singbox
}

# 配置函数
config_vless(){
    info "正在配置 VLESS Reality..."
    local port=443
    
    open_port "$port" "tcp"

    local dest_domain="$DEFAULT_DOMAIN"
    local uuid=$(get_random_uuid)
    local short_id=$(openssl rand -hex 4)
    local keys=$("$SINGBOX_BIN" generate reality-keypair)
    local private_key=$(echo "$keys" | grep "PrivateKey" | cut -d: -f2 | tr -d ' \\"')
    local public_key=$(echo "$keys" | grep "PublicKey" | cut -d: -f2 | tr -d ' \\"')

    local inbound=$(jq -n --arg port "$port" --arg uuid "$uuid" --arg dest "$dest_domain" --arg pk "$private_key" --arg sid "$short_id" '
        {
            type: "vless",
            tag: "vless-reality",
            listen: "::",
            listen_port: ($port|tonumber),
            users: [
                {
                    uuid: $uuid,
                    flow: "xtls-rprx-vision"
                }
            ],
            tls: {
                enabled: true,
                server_name: $dest,
                reality: {
                    enabled: true,
                    handshake: {
                        server: $dest,
                        server_port: 443
                    },
                    private_key: $pk,
                    short_id: [$sid]
                }
            }
        }
    ')

    add_inbound "$inbound"
    info "VLESS Reality 已配置完成。"
    echo "UUID: $uuid"
    echo "公钥: $public_key"
    echo "短 ID: $short_id"
    echo "端口: $port"
    echo "域名: $dest_domain"
}

config_hy2(){
    info "正在配置 Hysteria2..."
    local port=$(get_preferred_port "hysteria2")
    info "自动选择端口: $port"
    
    open_port "$port" "udp"
    
    local password=$(get_random_password)

    local tls_config=$(generate_tls_config)

    # 询问是否启用 obfs
    local obfs_config='{}'
    read -rp "是否启用 obfs 混淆？[y/N]: " enable_obfs
    if [[ "$enable_obfs" =~ ^[Yy]$ ]]; then
        local obfs_password=$(get_random_password)
        obfs_config=$(jq -n --arg pass "$obfs_password" '
            {
                type: "salamander",
                password: $pass
            }
        ')
    fi

    # 端口跳变逻辑已移除，移至主菜单单独配置

    local inbound=$(jq -n --arg port "$port" --arg pass "$password" --argjson tls "$tls_config" --argjson obfs "$obfs_config" --arg domain "$DEFAULT_DOMAIN" '
        {
            type: "hysteria2",
            tag: "hysteria2-in",
            listen: "::",
            listen_port: ($port|tonumber),
            users: [
                {
                    password: $pass
                }
            ],
            tls: $tls,
            masquerade: {
                type: "proxy",
                url: "https://\($domain)",
                rewrite_host: true
            }
        } + (if $obfs != {} then {obfs: $obfs} else {} end)
    ')

    add_inbound "$inbound"
    info "Hysteria2 已配置完成。"
    echo "密码: $password"
    echo "端口: $port"
    if [[ "$obfs_config" != "{}" ]]; then
        echo "Obfs 密码: $(echo "$obfs_config" | jq -r '.password')"
    fi
}

config_tuic(){
    info "正在配置 TUIC v5..."
    local port=$(get_preferred_port "tuic")
    info "自动选择端口: $port"
    
    open_port "$port" "udp"
    
    local uuid=$(get_random_uuid)
    local password=$(get_random_password)

    local tls_config=$(generate_tls_config)
    
    local inbound=$(jq -n --arg port "$port" --arg uuid "$uuid" --arg pass "$password" --argjson tls "$tls_config" '
        {
            type: "tuic",
            tag: "tuic-in",
            listen: "::",
            listen_port: ($port|tonumber),
            users: [
                {
                    name: "cloudyun",
                    uuid: $uuid,
                    password: $pass
                }
            ],
            congestion_control: "bbr",
            auth_timeout: "3s",
            zero_rtt_handshake: true,
            tls: $tls
        }
    ')

    add_inbound "$inbound"
    info "TUIC v5 已配置完成。"
    echo "UUID: $uuid"
    echo "密码: $password"
    echo "端口: $port"
}

clear_config(){ 
    info "正在清除入栈配置..."
    
    # 清除证书文件
    local cert_files=(
        "$SINGBOX_CONF_DIR/singbox.crt"
        "$SINGBOX_CONF_DIR/singbox.key"
    )
    
    local cert_found=false
    for cert_file in "${cert_files[@]}"; do
        if [[ -f "$cert_file" ]]; then
            rm -f "$cert_file"
            cert_found=true
        fi
    done
    
    if [[ "$cert_found" == true ]]; then
        info "证书文件已清理。"
    fi
    
    # 只清除入栈配置，保留出站配置
    jq '.inbounds = []' "$SINGBOX_CONF_PATH" > "${SINGBOX_CONF_PATH}.tmp" && mv "${SINGBOX_CONF_PATH}.tmp" "$SINGBOX_CONF_PATH"
    
    # 清理防火墙
    if command -v nft >/dev/null; then
        nft flush table inet singbox_nat || true
        nft delete table inet singbox_nat || true
        nft delete table inet singbox_filter || true
    elif command -v firewall-cmd >/dev/null; then
        warn "Firewalld 用户请注意：脚本无法自动精确删除所有开放端口，请手动检查 'firewall-cmd --list-all'。"
        firewall-cmd --reload
    fi
    
    restart_singbox
    info "入栈配置已清除。"
}

run_test_script(){ bash <(curl -Ls Check.Place); }
run_bbr(){ bash <(curl -l -s https://raw.githubusercontent.com/byJoey/Actions-bbr-v3/refs/heads/main/install.sh); }
uninstall_singbox(){ 
    rm -rf "$SINGBOX_BIN" "$SINGBOX_CONF_DIR"
    
    # 清理防火墙
    if command -v nft >/dev/null; then
        nft flush table inet singbox_nat || true
        nft delete table inet singbox_nat || true
        nft delete table inet singbox_filter || true
    fi
    
    if [[ "$RELEASE" == "alpine" ]]; then
        rc-service sing-box stop || true
        rc-update del sing-box || true
        rm /etc/init.d/sing-box || true
    else
        systemctl disable --now sing-box || true
        rm /etc/systemd/system/sing-box.service || true
        systemctl daemon-reload || true
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
    echo "5. 配置防火墙转发(只支持nftable)"
    echo "6. 清除入栈配置"
    echo "7. 卸载 Sing-box"
    echo "8. 服务器相关测试"
    echo "9. 安装 BBRv3(若想要更好的优化,可前往https://xanmod.org/)"
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
