#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# 脚本信息和说明
###############################################################################

# 精简版安装脚本：VLESS+XTLS+REALITY (Xray) + Hysteria2
# 官方安装脚本和对应目录
# hy：/etc/hysteria/
# 安装或升级到最新版本。
# bash <(curl -fsSL https://get.hy2.sh/)
# 移除 Hysteria 及相关服务
# bash <(curl -fsSL https://get.hy2.sh/) --remove

# xray：
# 安装目录/usr/local/share/xray/
# 配置文件目录/usr/local/etc/xray/
# 安装并升级 Xray-core 和地理数据，默认使用 User=nobody，但不会覆盖已有服务文件中的 User 设置
# bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
# 移除 Xray，包括 json 配置文件和日志
# bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge

# 对于alpine linux
# 安装 cURL
# apk add curl
# 下载安装脚本
# curl -O -L https://github.com/XTLS/Xray-install/raw/main/alpinelinux/install-release.sh
# 运行安装脚本
# ash install-release.sh
# 管理命令
# 启用 Xray 服务 (开机自启)
# rc-update add xray
# 禁用 Xray 服务 (取消自启)
# rc-update del xray
# 运行 Xray
# rc-service xray start
# 停止 Xray
# rc-service xray stop
# 重启 Xray
# rc-service xray restart

###############################################################################
# 日志和错误处理函数
###############################################################################

info(){ echo -e "\e[1;34m[信息]\e[0m $*"; }
warn(){ echo -e "\e[1;33m[警告]\e[0m $*"; }
err(){ echo -e "\e[1;31m[错误]\e[0m $*"; }

###############################################################################
# 权限检查
###############################################################################

# 需要root权限
if [[ "$(id -u)" -ne 0 ]]; then
  err "请以 root 用户执行本脚本（或使用 sudo）。退出。"
  exit 1
fi

###############################################################################
# 环境检查和包管理器检测
###############################################################################

# 检测包管理器/发行版
PM=""
if command -v apt-get >/dev/null 2>&1; then PM=apt
elif command -v dnf >/dev/null 2>&1; then PM=dnf
elif command -v yum >/dev/null 2>&1; then PM=yum
elif command -v apk >/dev/null 2>&1; then PM=apk
fi

info "检测到包管理器: ${PM:-(unknown)}"

# 环境检查和基本工具安装
setup_environment() {
  info "检查系统环境和必要工具..."
  
  # 合并工具检查，减少重复代码
  local tools_to_check=("bash" "grep" "curl" "cat" "cp" "mv" "rm" "mkdir" "chmod" "chown" "ls" "sed" "awk" "useradd")
  local missing_tools=()
  local busybox_tools=()
  
  # 统一检查所有工具
  for tool in "${tools_to_check[@]}"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      missing_tools+=("$tool")
    elif [[ "$tool" != "useradd" ]] && "$tool" --version 2>&1 | grep -qi "busybox" >/dev/null 2>&1; then
      busybox_tools+=("$tool")
    fi
  done
  
  # 安装缺失工具（包括useradd）
  if [ ${#missing_tools[@]} -gt 0 ] || [ ${#busybox_tools[@]} -gt 0 ]; then
    info "安装必要工具..."
    install_tools_by_pm
  fi
  
  # 验证useradd安装状态
  if command -v useradd >/dev/null 2>&1; then
    info "useradd 已安装"
  else
    warn "useradd 安装失败，某些功能可能受限"
  fi
  
  info "环境检查完成，所有必要工具已准备就绪。"
}

# 根据包管理器安装工具
install_tools_by_pm() {
  case "$PM" in
    apt)
      apt-get update -y
      apt-get install -y curl wget openssl coreutils bash grep passwd shadow nano || true
      ;;
    yum)
      yum install -y curl wget openssl coreutils bash grep shadow-utils nano || true
      ;;
    dnf)
      dnf install -y curl wget openssl coreutils bash grep shadow-utils nano || true
      ;;
    apk)
      apk add --no-cache curl wget openssl bash grep shadow nano || true
      apk add --no-cache -X http://dl-cdn.alpinelinux.org/alpine/edge/community findutils || true
      ;;
    *)
      warn "无法识别包管理器，请确保必要工具已安装。"
      ;;
  esac
}

# 执行环境检查和工具安装
setup_environment

###############################################################################
# 配置变量和辅助函数
###############################################################################

# 全局变量 - 目标域名
TARGET_DOMAIN="www.cho-kaguyahime.com"

# 默认值
XRAY_PORT_TCP=443
HY2_PORT_UDP=443
XRAY_CONF_DIR="/usr/local/etc/xray"
XRAY_CONF_PATH="$XRAY_CONF_DIR/config.json"
HY_CONF_DIR="/etc/hysteria"
HY_CONF_PATH="$HY_CONF_DIR/config.yaml"
HY_BIN_PATH="$HY_CONF_DIR/hysteria"

# 辅助函数
gen_uuid() {
  if command -v xray >/dev/null 2>&1; then
    xray uuid
    return 0
  fi
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen
    return 0
  fi
  err "无法生成 UUID，请确保安装了 xray 或 uuidgen 命令"
  return 1
}

rand_hex(){ openssl rand -hex "${1:-16}"; }

# 防火墙检测函数
check_firewall() {
  # 检测nft是否存在（仅使用nft）
  HAS_NFT=false
  if command -v nft >/dev/null 2>&1; then
    HAS_NFT=true
    info "检测到 nft，可用。"
  else
    warn "未检测到 nft，将跳过防火墙自动配置。"
  fi
}


# 执行防火墙检测
check_firewall

###############################################################################
# 用户菜单
###############################################################################

# 菜单
cat <<'MENU'
请选择要执行的操作（输入数字）:
  1) 安装 VLESS + XTLS + REALITY (Xray)
  2) 安装 Hysteria2
  3) 删除 Xray
  4) 删除 Hysteria2
  5) IP 质量检测（若运行时卡住，可能是因为内存不足）
MENU
read -rp "选择 (1/2/3/4/5) [1]: " CHOICE
CHOICE=${CHOICE:-1}
INSTALL_XRAY=false
INSTALL_HY2=false
REMOVE_XRAY=false
REMOVE_HY2=false
CHECK_IP=false
[[ "$CHOICE" == "1" ]] && INSTALL_XRAY=true
[[ "$CHOICE" == "2" ]] && INSTALL_HY2=true
[[ "$CHOICE" == "3" ]] && REMOVE_XRAY=true
[[ "$CHOICE" == "4" ]] && REMOVE_HY2=true
[[ "$CHOICE" == "5" ]] && CHECK_IP=true

###############################################################################
# 删除函数
###############################################################################
# 删除 Xray
remove_xray() {
  info "开始删除 Xray..."
  
  if [[ "$PM" == "apk" ]]; then
    info "检测到 Alpine 系统，使用 Alpine 专用删除流程..."
    rc-service xray stop 2>/dev/null || true
    rc-update del xray 2>/dev/null || true
    rm -rf /usr/local/bin/xray /usr/local/share/xray /usr/local/etc/xray /var/log/xray /etc/init.d/xray 2>/dev/null || true
    apk del unzip 2>/dev/null || true
    info "Alpine 系统上的 Xray 已删除"
  else
    info "使用官方删除脚本删除 Xray..."
    if bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge; then
      info "Xray 官方删除脚本已执行"
    else
      err "执行 Xray 官方删除脚本失败，请手动检查"
    fi
  fi
}

# 删除 Hysteria2
remove_hy2() {
  info "开始删除 Hysteria2..."
  
  if [[ "$PM" == "apk" ]]; then
    info "检测到 Alpine 系统，使用 Alpine 专用删除流程..."
    rc-service hysteria stop 2>/dev/null || true
    rc-update del hysteria 2>/dev/null || true
    rm -f /etc/init.d/hysteria 2>/dev/null || true
    rm -f "$HY_BIN_PATH" 2>/dev/null || true
    rm -rf "$HY_CONF_DIR" 2>/dev/null || true
    info "Alpine 系统上的 Hysteria2 已删除"
  else
    info "使用官方删除脚本删除 Hysteria2..."
    if bash <(curl -fsSL https://get.hy2.sh/) --remove; then
      info "Hysteria2 官方删除脚本已执行"
    else
      err "执行 Hysteria2 官方删除脚本失败，请手动检查"
    fi
  fi
}

# IP 质量检测
check_ip_quality() {
  info "开始进行 IP 质量检测..."
  info "使用 IPQuality 工具检测当前服务器 IP 的质量"
  echo "===================================="
  
  # 执行 IP 质量检测
  if bash <(curl -Ls https://IP.Check.Place); then
    info "IP 质量检测完成"
  else
    err "IP 质量检测失败，请检查网络连接或稍后重试"
  fi
  
  echo "===================================="
  info "IP 质量检测结束"
}

# 执行删除操作
if [[ "$REMOVE_XRAY" == "true" ]]; then
  remove_xray
fi

if [[ "$REMOVE_HY2" == "true" ]]; then
  remove_hy2
fi

# 执行 IP 质量检测
if [[ "$CHECK_IP" == "true" ]]; then
  check_ip_quality
fi

# 如果只是删除操作或IP检测，完成后退出
if [[ "$REMOVE_XRAY" == "true" || "$REMOVE_HY2" == "true" || "$CHECK_IP" == "true" ]] && [[ "$INSTALL_XRAY" != "true" && "$INSTALL_HY2" != "true" ]]; then
  info "操作完成"
  exit 0
fi

###############################################################################
# XRAY 安装与配置 (VLESS + REALITY)
###############################################################################
if [[ "$INSTALL_XRAY" == "true" ]]; then
  info "开始安装 Xray (VLESS+REALITY) — 使用官方推荐流程（优先尝试官方安装脚本）。"

  # 先执行安装操作
  if [[ "$PM" == "apk" ]]; then
    info "检测到 Alpine：使用 Xray 官方 Alpine 安装脚本。"
    curl -fsSL -o /tmp/xray-alpine-install.sh https://github.com/XTLS/Xray-install/raw/main/alpinelinux/install-release.sh || true
    if [[ -f /tmp/xray-alpine-install.sh ]]; then
      ash /tmp/xray-alpine-install.sh || warn "运行 Xray Alpine 安装脚本失败，请手动检查。"
    else
      warn "无法下载 Xray Alpine 安装脚本，跳过自动安装步骤。"
    fi
  else
    # 尝试主安装程序（适用于许多发行版）
    info "正在执行 Xray 官方安装脚本..."
    if bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install; then
      info "Xray 官方安装脚本已执行（或已安装）。"
    else
      err "执行 Xray 官方安装脚本失败，可能是网络问题或连接被重置。请检查网络连接或手动安装 Xray。"
      warn "脚本将生成示例配置供手动部署，但 Xray 可能未正确安装。"
    fi
  fi

  # 安装完成后，再进行配置
  mkdir -p "$XRAY_CONF_DIR"

  # 自动生成 UUID
  VLESS_UUID="$(gen_uuid)"
  info "自动生成 VLESS UUID: ${VLESS_UUID}"

  # 尝试使用 xray x25519 生成密钥
  XRAY_PRIV=""; XRAY_PUB=""
  if command -v xray >/dev/null 2>&1; then
    info "尝试运行 'xray x25519' 生成 X25519 密钥对（若可用）..."
    tmpf=$(mktemp)
    if xray x25519 >"$tmpf" 2>/dev/null; then
      XRAY_PRIV="$(grep -i '^PrivateKey:' "$tmpf" | awk '{print $2}' || true)"
      XRAY_PUB="$(grep -i '^Password:' "$tmpf" | awk '{print $2}' || true)"
    fi
    rm -f "$tmpf" || true
  else
    warn "未检测到 xray 二进制，无法自动生成 x25519 key。可在安装后运行 'xray x25519' 并将 privateKey 填入配置。"
  fi

  # 固定 REALITY dest / serverNames
  REALITY_DEST="${TARGET_DOMAIN}:443"
  REALITY_SNI_JSON="${TARGET_DOMAIN}"


  info "写入 Xray 配置到: $XRAY_CONF_PATH"
  cat > "$XRAY_CONF_PATH" <<JSON
{
  "log": { "loglevel": "none" },
  "inbounds": [
    {
      "listen": "::",
      "port": ${XRAY_PORT_TCP},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${VLESS_UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none",
        "fallbacks": [
          {
            "dest": 8443
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "dest": "${REALITY_DEST}",
          "serverNames": ["${REALITY_SNI_JSON}"],
          "privateKey": "${XRAY_PRIV}",
          "shortIds": ["","aqwsderf"]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http","tls","quic"],
        "routeOnly": true
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" }
  ]
}
JSON

  # 尝试启用/重启 xray 服务
  if command -v systemctl >/dev/null 2>&1; then
    # systemctl daemon-reload || true
    systemctl restart xray || true
  elif [[ "$PM" == "apk" ]]; then
    # 在 Alpine 上 openrc 可能被 Xray 安装程序使用
    if command -v rc-update >/dev/null 2>&1; then
      rc-update add xray || true
      rc-service xray start || true
    fi
  else
    warn "未检测到标准 xray service unit，可能需手动启动或检查安装路径。"
  fi
fi

###############################################################################
# HYSTERIA2 安装与配置
###############################################################################
if [[ "$INSTALL_HY2" == "true" ]]; then
  info "开始安装 Hysteria2（优先尝试官方安装器，若为 Alpine 使用轻量二进制+openrc 流程）。"

  # 先执行安装操作
  if [[ "$PM" == "apk" ]]; then
    info "检测到 Alpine — 使用二进制下载 + openrc 注册 hysteria（参考 Alpine 专用流程）。"
    mkdir -p "$HY_CONF_DIR"
    
    # 检测系统架构
    ARCH=$(uname -m)
    case "$ARCH" in
      x86_64)
        HY_ARCH="hysteria-linux-amd64"
        info "检测到 x86_64 架构，将下载 amd64 版本"
        ;;
      aarch64|arm64)
        HY_ARCH="hysteria-linux-arm64"
        info "检测到 aarch64/arm64 架构，将下载 arm64 版本"
        ;;
      *)
        warn "不支持的架构: $ARCH，将默认使用 amd64 版本"
        HY_ARCH="hysteria-linux-amd64"
        ;;
    esac
    
    # 尝试下载最新的 hysteria 二进制
    if wget -q -O "$HY_BIN_PATH" "https://download.hysteria.network/app/latest/${HY_ARCH}" --no-check-certificate; then
      chmod 777 "$HY_BIN_PATH"
      info "hysteria 二进制已下载到 ${HY_BIN_PATH}"
    else
      warn "无法下载 hysteria 二进制，考虑使用官方安装脚本或检查网络。"
    fi
  else
    # 为非 Alpine 系统尝试官方安装程序
    info "正在执行 Hysteria2 官方安装脚本..."
    if bash <(curl -fsSL https://get.hy2.sh/); then
      info "调用 Hysteria 官方安装器完成（或已安装）。"
    else
      err "调用 Hysteria 官方安装器失败，已生成配置供手动部署。"
    fi
  fi

  # 安装完成后，再进行配置
  mkdir -p "$HY_CONF_DIR"

  # 自动生成 Hysteria 密码（auth）
  HY_PASS="$(rand_hex 16)"
  info "自动生成 Hysteria password: $HY_PASS"

  # 混淆可选
  read -rp "是否启用混淆?这会使得外部看起来是随机字节流,但会失去http3伪装 [y/N]: " _ob
  HY_OBFS=false
  HY_OBFS_PASS=""
  if [[ "${_ob,,}" =~ ^y(es)?$ ]]; then
    HY_OBFS=true
    HY_OBFS_PASS="$(rand_hex 8)"
    info "已为 obfs 生成密码: $HY_OBFS_PASS"
  fi

  # TLS 选择：ACME 或 自签名（不再接受已有证书文件）
  echo
  echo "Hysteria TLS 选择："
  select opt in "ACME 自动（需域名解析）" "生成自签名证书 (默认)"; do
    case $REPLY in
      1) HY_TLS_MODE="acme"; break;;
      2) HY_TLS_MODE="self"; break;;
      *) echo "请输入 1 或 2";;
    esac
  done

  HY_TLS_CERT=""; HY_TLS_KEY=""; HY_DOMAIN=""; HY_EMAIL=""
  if [[ "$HY_TLS_MODE" == "acme" ]]; then
    read -rp "请输入域名（必须解析到此 VPS IP）: " HY_DOMAIN
    read -rp "ACME 邮箱: " HY_EMAIL
    # 对于 Alpine，acme 可由 get.hy2.sh 处理或使用 acme.sh
  else
    info "生成自签名证书到 /etc/hysteria/server.crt & server.key"
    mkdir -p "$HY_CONF_DIR"
    # 创建基本的自签名证书配置文件
    openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) -keyout /etc/hysteria/server.key -out /etc/hysteria/server.crt -subj "/CN=${TARGET_DOMAIN}" -days 36500 && sudo chown hysteria /etc/hysteria/server.key && sudo chown hysteria /etc/hysteria/server.crt

    HY_TLS_CERT="/etc/hysteria/server.crt"
    HY_TLS_KEY="/etc/hysteria/server.key"
    HY_TLS_MODE="file"
  fi

  # 为YAML构建 obfs 块和 tls 块
  OBFS_BLOCK=""
  if $HY_OBFS; then
    OBFS_BLOCK=$(cat <<-YOB
obfs:
  type: salamander
  salamander:
    password: "${HY_OBFS_PASS}"
YOB
)
  fi

  if [[ "$HY_TLS_MODE" == "acme" ]]; then
    TLS_BLOCK=$(cat <<-YTL

acme:
  domains:
    - ${HY_DOMAIN}
  email: "${HY_EMAIL:-}"
YTL
)
  else
    TLS_BLOCK=$(cat <<-YTL
tls:
  cert: "${HY_TLS_CERT}"
  key: "${HY_TLS_KEY}"
YTL
)
  fi

  # 写入 hysteria 配置
  info "写入 Hysteria 配置到 ${HY_CONF_PATH}"
  cat > "$HY_CONF_PATH" <<YAML
listen: :${HY2_PORT_UDP}

${TLS_BLOCK}

auth:
  type: password
  password: "${HY_PASS}"

${OBFS_BLOCK}

masquerade:
  type: proxy
  proxy:
    url: https://${TARGET_DOMAIN}/
    rewriteHost: true
YAML

  # 设置配置文件最宽松权限
  chmod 777 "$HY_CONF_PATH"

  # 尝试启用/重启 hysteria 服务
  if [[ "$PM" == "apk" ]]; then
    # 创建 openrc 服务文件
    cat > "/etc/init.d/hysteria" <<'EOF'
#!/sbin/openrc-run

name="hysteria"
command="/etc/hysteria/hysteria"
command_args="server --config /etc/hysteria/config.yaml"
pidfile="/var/run/${name}.pid"
command_background="yes"

depend() {
        need networking
}
EOF
    chmod +x /etc/init.d/hysteria
    rc-update add hysteria default || true
    rc-service hysteria restart || warn "尝试启动 hysteria 服务失败，请手动检查。"
  else
    # 如果可用，尝试启用 systemd
    if command -v systemctl >/dev/null 2>&1; then
      systemctl enable hysteria-server.service || true
      systemctl restart hysteria-server.service || warn "无法自动重启 hysteria-server，请手动检查 systemctl status hysteria-server.service"
    fi
  fi
fi

###############################################################################
# 防火墙: 使用 nft 添加允许规则（仅 nft）
###############################################################################
info "为 TCP 443 与 UDP 443 端口添加 nft 入站允许规则（若支持 nft）..."

if $HAS_NFT; then
  nft list table inet filter >/dev/null 2>&1 || nft add table inet filter
  nft list chain inet filter input >/dev/null 2>&1 || nft add chain inet filter input { type filter hook input priority 0 \; policy accept \; }

  nft add rule inet filter input tcp dport 443 ct state new,established accept >/dev/null 2>&1 || true
  nft add rule inet filter input udp dport 443 ct state new,established accept >/dev/null 2>&1 || true

  info "已向 nft 添加放行规则 (tcp 443, udp 443)。"
else
  warn "系统未安装或找不到 nft，已跳过自动添加防火墙规则。请手动放行443端口。"
fi

# 持久化 nft 选项（仅当 nft 可用时）
if $HAS_NFT; then
  nft list ruleset > /etc/nftables.conf
  info "已导出 /etc/nftables.conf。"
fi

###############################################################################
# 检测并开启 BBR
###############################################################################
info "检测并开启 BBR (TCP 拥塞控制算法)..."

# 解析内核主/次版本（如 5.10）
KERNEL_VERSION=$(uname -r | cut -d- -f1)   # 去掉 -generic 等后缀
KERNEL_MAJOR=$(echo "$KERNEL_VERSION" | cut -d. -f1)
KERNEL_MINOR=$(echo "$KERNEL_VERSION" | cut -d. -f2)

# 比较版本：需要 >= 4.9
if [ -z "$KERNEL_MAJOR" ] || [ -z "$KERNEL_MINOR" ]; then
  warn "无法解析内核版本: '$KERNEL_VERSION'"
else
  if [ "$KERNEL_MAJOR" -gt 4 ] || { [ "$KERNEL_MAJOR" -eq 4 ] && [ "$KERNEL_MINOR" -ge 9 ]; }; then
    info "内核版本 ${KERNEL_VERSION} 支持 BBR（>= 4.9）"
    # 尝试加载模块（若内核编译为模块）
    if ! lsmod | grep -q '^tcp_bbr'; then
      info "尝试加载 tcp_bbr 模块..."
      if modprobe tcp_bbr 2>/dev/null; then
        info "tcp_bbr 模块加载成功"
      else
        warn "无法通过 modprobe 加载 tcp_bbr（可能已编进内核或内核不支持）。继续尝试设置 sysctl。"
      fi
    else
      info "tcp_bbr 模块已加载"
    fi

    # 幂等地设置 /etc/sysctl.conf（替换已存在的项或追加）
    set_sysctl() {
      key="$1"; val="$2"
      if grep -q -E "^\s*${key}\s*=" /etc/sysctl.conf 2>/dev/null; then
        sed -ri "s|^\s*(${key})\s*=.*|\1=${val}|" /etc/sysctl.conf
      else
        echo "${key}=${val}" >> /etc/sysctl.conf
      fi
    }

    set_sysctl "net.core.default_qdisc" "fq"
    set_sysctl "net.ipv4.tcp_congestion_control" "bbr"

    # 立刻生效（只加载 sysctl.conf）
    if sysctl -p /etc/sysctl.conf >/dev/null 2>&1; then
      info "sysctl 配置已加载 (/etc/sysctl.conf)"
    else
      warn "sysctl -p 加载 /etc/sysctl.conf 时出现问题，尝试 sysctl --system"
      sysctl --system || warn "sysctl --system 也失败，请手动检查"
    fi

    # 验证
    CURRENT_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
    CURRENT_QDISC=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "")
    if [ "$CURRENT_CC" = "bbr" ]; then
      info "BBR 已成功设置为 tcp_congestion_control=$CURRENT_CC"
    else
      warn "设置后检测到 tcp_congestion_control=$CURRENT_CC（期望 bbr）。"
      warn "可尝试：modprobe tcp_bbr; dmesg | tail -n 50 查找相关报错；或确认内核是否启用 CONFIG_TCP_CONG_BBR"
    fi
    info "当前默认 qdisc = $CURRENT_QDISC"

  else
    warn "内核版本 ${KERNEL_VERSION} 不支持 BBR，需要 4.9 或更高版本"
  fi
fi

###############################################################################
# 输出结果
###############################################################################

echo
info "================= 配置完成 — 以下为生成的配置文件/要点 ================="

after_exit(){
  # 只在安装操作完成后显示配置信息
  if [[ "$INSTALL_XRAY" == "true" || "$INSTALL_HY2" == "true" ]]; then
    if [[ "$INSTALL_XRAY" == "true" ]]; then
      echo "VLESS 连接要点："
      echo "  - UUID: ${VLESS_UUID}"
      echo "  - X25519 public: ${XRAY_PUB}"
      echo "  - shortIds:可以不填写或填写1234"
      echo
    fi

    if [[ "$INSTALL_HY2" == "true" ]]; then
      echo "Hysteria 连接要点："
      echo "  - password: ${HY_PASS}"
      if $HY_OBFS; then echo "  - obfs: salamander (password: ${HY_OBFS_PASS})"; fi
      echo "如需端口跳跃，请手动配置端口转发，然后在客户端使用你的转发的端口范围连接"
      echo
    fi

    echo "若准备使用不同端口连接,请手动配置端口转发到443端口,并在客户端使用你的转发的端口连接"

    echo
    info "================= 安装目录信息 ================="
    echo "各组件的安装目录和配置文件位置："
    echo
    if [[ "$INSTALL_XRAY" == "true" ]]; then
      echo "----- Xray -----"
      echo "  - 安装目录: /usr/local/share/xray/"
      echo "  - 配置文件目录: /usr/local/etc/xray/"
      echo "  - 配置文件: $XRAY_CONF_PATH"
      echo
    fi

    if [[ "$INSTALL_HY2" == "true" ]]; then
      echo "----- Hysteria2 -----"
      echo "  - 安装目录: $HY_CONF_DIR"
      echo "  - 配置文件: $HY_CONF_PATH"
      if [[ "$PM" == "apk" ]]; then
        echo "  - 二进制文件: $HY_BIN_PATH"
      fi
      echo
    fi

    echo
    info "================= 服务管理命令 ================="
    echo "根据您的系统类型，使用以下命令管理服务："
    echo
    if command -v systemctl >/dev/null 2>&1; then
      echo "----- systemd 系统 (如 Ubuntu, CentOS, Debian 等) -----"
      [[ "$INSTALL_XRAY" == "true" ]] && echo "Xray 服务:"
      [[ "$INSTALL_XRAY" == "true" ]] && echo "  - 状态检查: systemctl status xray"
      [[ "$INSTALL_XRAY" == "true" ]] && echo "  - 设置开机启动: systemctl enable xray"
      [[ "$INSTALL_XRAY" == "true" ]] && echo "  - 关闭开机启动: systemctl disable xray"
      [[ "$INSTALL_XRAY" == "true" ]] && echo ""
      [[ "$INSTALL_HY2" == "true" ]] && echo "Hysteria 服务:"
      if [[ "$INSTALL_HY2" == "true" ]]; then
        if [[ "$PM" == "apk" ]]; then
          echo "  - 状态检查: systemctl status hysteria"
          echo "  - 设置开机启动: systemctl enable hysteria"
          echo "  - 关闭开机启动: systemctl disable hysteria"
        else
          echo "  - 状态检查: systemctl status hysteria-server.service"
          echo "  - 设置开机启动: systemctl enable hysteria-server.service"
          echo "  - 关闭开机启动: systemctl disable hysteria-server.service"
        fi
      fi
    elif command -v rc-update >/dev/null 2>&1; then
      echo "----- OpenRC 系统 (如 Alpine Linux 等) -----"
      [[ "$INSTALL_XRAY" == "true" ]] && echo "Xray 服务:"
      [[ "$INSTALL_XRAY" == "true" ]] && echo "  - 状态检查: rc-service xray status"
      [[ "$INSTALL_XRAY" == "true" ]] && echo "  - 设置开机启动: rc-update add xray"
      [[ "$INSTALL_XRAY" == "true" ]] && echo "  - 关闭开机启动: rc-update del xray"
      [[ "$INSTALL_XRAY" == "true" ]] && echo ""
      [[ "$INSTALL_HY2" == "true" ]] && echo "Hysteria 服务 (Alpine 系统使用 hysteria 作为服务名):"
      [[ "$INSTALL_HY2" == "true" ]] && echo "  - 状态检查: rc-service hysteria status"
      [[ "$INSTALL_HY2" == "true" ]] && echo "  - 设置开机启动: rc-update add hysteria"
      [[ "$INSTALL_HY2" == "true" ]] && echo "  - 关闭开机启动: rc-update del hysteria"
    else
      echo "----- 未知系统类型 -----"
      echo "请根据您的系统类型手动管理服务"
      [[ "$INSTALL_XRAY" == "true" ]] && echo "Xray 服务可能的管理命令："
      [[ "$INSTALL_XRAY" == "true" ]] && echo "  - 状态检查: systemctl status xray / rc-service xray status / service xray status"
      [[ "$INSTALL_XRAY" == "true" ]] && echo "  - 开机启动: systemctl enable/disable xray / rc-update add/del xray"
      [[ "$INSTALL_XRAY" == "true" ]] && echo ""
      [[ "$INSTALL_HY2" == "true" ]] && echo "Hysteria 服务可能的管理命令："
      if [[ "$INSTALL_HY2" == "true" ]]; then
        if [[ "$PM" == "apk" ]]; then
          echo "  - 状态检查: systemctl status hysteria / rc-service hysteria status / service hysteria status"
          echo "  - 开机启动: systemctl enable/disable hysteria / rc-update add/del hysteria"
        else
          echo "  - 状态检查: systemctl status hysteria-server.service / rc-service hysteria-server.service / service hysteria-server.service"
          echo "  - 开机启动: systemctl enable/disable hysteria-server.service / rc-update add/del hysteria-server.service"
        fi
      fi
    fi
  fi
  
  # 如果执行了删除操作，显示删除完成提示
  if [[ "$REMOVE_XRAY" == "true" || "$REMOVE_HY2" == "true" ]]; then
    echo
    info "================= 删除操作完成 ================="
    echo "已删除所选服务，相关配置文件和二进制文件已被移除。"
    echo "如果需要重新安装，请再次运行本脚本并选择安装选项。"
  fi
}

# 在结束时打印摘要
# 使用 trap 确保脚本在任何情况下都会调用 after_exit 函数
trap after_exit EXIT

# 脚本结束
