#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "$0")"

export FILE_PATH="${FILE_PATH:-${PWD}/.npm/video}"
export DATA_PATH="${DATA_PATH:-${PWD}/singbox_data}"
export HY2_PORT="${HY2_PORT:-20164}"
export HTTP_LISTEN_PORT="${HTTP_LISTEN_PORT:-$HY2_PORT}"
export TLS_CERT_IP="${TLS_CERT_IP:-51.75.118.151}"
export HY2_SNI="${HY2_SNI:-$TLS_CERT_IP}"
export TLS_CERT_CN="${TLS_CERT_CN:-$TLS_CERT_IP}"
export TLS_CERT_DNS="${TLS_CERT_DNS:-$HY2_SNI}"
export TLS_CERT_PATH="${TLS_CERT_PATH:-${FILE_PATH}/cert.pem}"
export TLS_KEY_PATH="${TLS_KEY_PATH:-${FILE_PATH}/private.key}"
export SINGBOX_BIN="${SINGBOX_BIN:-${FILE_PATH}/sing-box}"
export SINGBOX_AUTO_UPDATE="${SINGBOX_AUTO_UPDATE:-1}"
export SINGBOX_MIN_FREE_MB="${SINGBOX_MIN_FREE_MB:-120}"
export STARTUP_LOG="${STARTUP_LOG:-${FILE_PATH}/singbox_startup.log}"

mkdir -p "$FILE_PATH" "$DATA_PATH"

log() {
  local level="$1"; shift
  local line
  line="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*"
  printf '%s\n' "$line"
  printf '%s\n' "$line" >> "$STARTUP_LOG" 2>/dev/null || true
}

section() { log "STEP" "========== $* =========="; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

fetch_text() {
  local url="$1"
  if have_cmd curl; then
    curl -fsSL --connect-timeout 8 --max-time 30 "$url"
  elif have_cmd wget; then
    wget -qO- --timeout=30 "$url"
  else
    log "ERROR" "未找到 curl 或 wget"
    return 1
  fi
}

download_file() {
  local url="$1" out="$2"
  log "INFO" "下载：$url -> $out"
  if have_cmd curl; then
    curl -fL --connect-timeout 8 --max-time 120 -o "$out" "$url"
  elif have_cmd wget; then
    wget -O "$out" --timeout=120 "$url"
  else
    log "ERROR" "未找到 curl 或 wget"
    return 1
  fi
}

free_mb() {
  df -Pm "$FILE_PATH" 2>/dev/null | awk 'NR==2 {print $4}' || echo 0
}

check_free_space() {
  local free
  free="$(free_mb)"
  log "INFO" "当前可用空间：${free} MiB"
  if [ -n "$free" ] && [ "$free" -lt "$SINGBOX_MIN_FREE_MB" ]; then
    log "ERROR" "空间不足：安装/更新 sing-box 至少建议 ${SINGBOX_MIN_FREE_MB} MiB"
    exit 1
  fi
}

setup_uuid() {
  section "初始化 HY2 密码"
  local uuid_file="$FILE_PATH/uuid.txt"
  if [ -f "$uuid_file" ]; then
    UUID="$(cat "$uuid_file")"
    log "INFO" "[HY2] 复用固定密码：$UUID"
  else
    UUID="$(cat /proc/sys/kernel/random/uuid)"
    printf '%s\n' "$UUID" > "$uuid_file"
    chmod 600 "$uuid_file" || true
    log "INFO" "[HY2] 首次生成固定密码：$UUID"
  fi
  export UUID
}

setup_download_key() {
  section "初始化 Web 操作密钥"
  local key_file="$FILE_PATH/download_key.txt"
  if [[ -n "${DOWNLOAD_KEY:-}" ]]; then
    log "INFO" "[Web] 复用环境变量 DOWNLOAD_KEY：$DOWNLOAD_KEY"
  elif [ -f "$key_file" ]; then
    DOWNLOAD_KEY="$(cat "$key_file")"
    log "INFO" "[Web] 复用固定操作密钥：$DOWNLOAD_KEY"
  else
    DOWNLOAD_KEY="$(cat /proc/sys/kernel/random/uuid)"
    printf '%s\n' "$DOWNLOAD_KEY" > "$key_file"
    chmod 600 "$key_file" || true
    log "INFO" "[Web] 首次生成固定操作密钥：$DOWNLOAD_KEY"
  fi
  export DOWNLOAD_KEY
}

singbox_version() {
  local bin="$1"
  [ -x "$bin" ] || return 1
  "$bin" version 2>/dev/null | head -n 1
}

install_singbox() {
  section "检查 sing-box"
  check_free_space

  if [ -x "$SINGBOX_BIN" ] && [ "$SINGBOX_AUTO_UPDATE" != "1" ]; then
    log "INFO" "复用本地 sing-box：$SINGBOX_BIN version=$(singbox_version "$SINGBOX_BIN" || echo unknown)"
    return
  fi

  local arch sb_arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) sb_arch="amd64" ;;
    aarch64|arm64) sb_arch="arm64" ;;
    *) log "ERROR" "不支持的架构：$arch"; exit 1 ;;
  esac

  local latest_json latest_ver local_ver
  latest_json="$(fetch_text 'https://api.github.com/repos/SagerNet/sing-box/releases/latest')"
  latest_ver="$(printf '%s' "$latest_json" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\([^"]*\)".*/\1/p' | head -n 1)"
  if [ -z "$latest_ver" ]; then
    log "ERROR" "无法解析 sing-box 最新版本号"
    exit 1
  fi

  local_ver="$(singbox_version "$SINGBOX_BIN" 2>/dev/null | sed -n 's/.*version \([^ ]*\).*/\1/p' || true)"
  if [ -x "$SINGBOX_BIN" ] && [ "$local_ver" = "$latest_ver" ]; then
    log "INFO" "本地 sing-box 已是最新：$local_ver"
    return
  fi

  local tmp tarball url src
  tmp="$(mktemp -d)"
  tarball="sing-box-${latest_ver}-linux-${sb_arch}.tar.gz"
  url="https://github.com/SagerNet/sing-box/releases/download/v${latest_ver}/${tarball}"
  download_file "$url" "$tmp/$tarball"
  tar -xzf "$tmp/$tarball" -C "$tmp"
  src="$(find "$tmp" -type f -name sing-box -perm /111 -print -quit 2>/dev/null || true)"
  if [ -z "$src" ]; then
    log "ERROR" "压缩包中未找到 sing-box 二进制"
    exit 1
  fi
  mv -f "$src" "$SINGBOX_BIN.new"
  chmod +x "$SINGBOX_BIN.new"
  mv -f "$SINGBOX_BIN.new" "$SINGBOX_BIN"
  rm -rf "$tmp"
  log "INFO" "sing-box 已安装/更新：$SINGBOX_BIN version=$(singbox_version "$SINGBOX_BIN" || echo unknown)"
}

setup_cert_and_config() {
  section "生成证书和 sing-box 配置"

  local need_generate=0
  local early_renew_days="${TLS_EARLY_RENEW_DAYS:-30}"
  if [ ! -f "$TLS_KEY_PATH" ] || [ ! -f "$TLS_CERT_PATH" ]; then
    need_generate=1
  else
    if have_cmd openssl; then
      local not_after_sec now_sec diff_sec renew_sec
      not_after_sec="$(openssl x509 -noout -dates -in "$TLS_CERT_PATH" 2>/dev/null | grep notAfter | cut -d= -f2 | xargs date -d +%s 2>/dev/null || echo 0)"
      if [ "$not_after_sec" -eq 0 ]; then
        log "WARN" "无法读取证书有效期，强制重新生成"
        need_generate=1
      else
        now_sec="$(date +%s)"
        renew_sec="$(( early_renew_days * 86400 ))"
        diff_sec="$(( not_after_sec - now_sec ))"
        if [ "$diff_sec" -le "$renew_sec" ]; then
          log "INFO" "证书将在 $(( diff_sec / 86400 )) 天后过期（或已过期），提前 $early_renew_days 天重新生成"
          need_generate=1
        fi
      fi
    fi
    if [ "$need_generate" -eq 0 ]; then
      log "INFO" "复用已有 TLS 证书：$TLS_CERT_PATH"
    fi
  fi

  if [ "$need_generate" -eq 1 ]; then
    if ! have_cmd openssl; then
      log "ERROR" "未找到 openssl，无法生成证书"
      exit 1
    fi
    local openssl_conf san_entries
    openssl_conf="$(mktemp)"
    san_entries="IP.1 = ${TLS_CERT_IP}"
    if [ -n "${TLS_CERT_DNS:-}" ] && [ "$TLS_CERT_DNS" != "$TLS_CERT_IP" ]; then
      san_entries="${san_entries}
DNS.1 = ${TLS_CERT_DNS}"
    fi
    cat > "$openssl_conf" <<EOF_OPENSSL
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
req_extensions = req_ext
x509_extensions = v3_ext

[dn]
C = FR
ST = Hauts-de-France
L = Roubaix
O = Roubaix Network Services
OU = Edge Web Runtime
CN = ${TLS_CERT_CN}

[req_ext]
subjectAltName = @alt_names

[v3_ext]
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
${san_entries}
EOF_OPENSSL
    log "INFO" "生成 ECDSA prime256v1 自签证书：CN=$TLS_CERT_CN SAN=IP:$TLS_CERT_IP DNS:$TLS_CERT_DNS 位置=FR/Hauts-de-France/Roubaix"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -sha256 -nodes -days 365 \
      -keyout "$TLS_KEY_PATH" \
      -out "$TLS_CERT_PATH" \
      -config "$openssl_conf"
    rm -f "$openssl_conf"
  fi
  chmod 600 "$TLS_KEY_PATH" || true

  cat > "$FILE_PATH/config.json" <<EOF_JSON
{
  "log": { "disabled": true },
  "inbounds": [
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": ${HY2_PORT},
      "users": [{ "password": "${UUID}" }],
      "masquerade": "http://127.0.0.1:${HTTP_LISTEN_PORT}",
      "tls": {
        "enabled": true,
        "server_name": "${HY2_SNI}",
        "alpn": ["h3"],
        "certificate_path": "${TLS_CERT_PATH}",
        "key_path": "${TLS_KEY_PATH}"
      }
    }
  ],
  "outbounds": [{ "type": "direct" }]
}
EOF_JSON
  log "INFO" "sing-box 配置已写入：$FILE_PATH/config.json"
}

SINGBOX_PID=""

start_singbox() {
  section "启动 sing-box / HY2"
  "$SINGBOX_BIN" run -c "$FILE_PATH/config.json" &
  SINGBOX_PID=$!
  export SINGBOX_PID
  sleep 1
  if ! kill -0 "$SINGBOX_PID" 2>/dev/null; then
    log "ERROR" "sing-box 启动失败"
    exit 1
  fi
  log "INFO" "sing-box 已启动：pid=$SINGBOX_PID udp_port=$HY2_PORT"
}

print_info() {
  section "连接信息"
  printf '\n================== 连接信息 ==================\n'
  printf '服务器 IP / 证书 IP: %s\n' "$TLS_CERT_IP"
  printf 'HY2 端口: %s/udp\n' "$HY2_PORT"
  printf 'HY2 密码: %s\n' "$UUID"
  printf 'TLS SNI: %s\n' "$HY2_SNI"
  printf '允许不安全证书: true\n'
  printf 'Web HTTPS: https://%s:%s/\n' "$TLS_CERT_IP" "$HTTP_LISTEN_PORT"
  if [[ -n "${DOWNLOAD_KEY:-}" ]]; then
    printf 'Web 操作密钥 DOWNLOAD_KEY: %s\n' "$DOWNLOAD_KEY"
  else
    printf 'Web 操作密钥 DOWNLOAD_KEY: 未设置，无需密码\n'
  fi
  printf '==============================================\n\n'
}

cleanup_on_exit() {
  local rc="$?"
  log "INFO" "sing-box 脚本退出：rc=$rc"
  if [ -n "${SINGBOX_PID:-}" ]; then kill "$SINGBOX_PID" 2>/dev/null || true; fi
}
trap cleanup_on_exit EXIT INT TERM

schedule_restart_loop() {
  section "进入 sing-box 守护循环"
  local last_day=-1
  while true; do
    if [ -n "${SINGBOX_PID:-}" ] && ! kill -0 "$SINGBOX_PID" 2>/dev/null; then
      log "ERROR" "sing-box 已退出，交给面板重启"
      exit 1
    fi

    local now bj h m d
    now="$(date +%s)"
    bj=$((now + 28800))
    h=$(((bj / 3600) % 24))
    m=$(((bj / 60) % 60))
    d=$((bj / 86400))
    if [ "$h" -eq 4 ] && [ "$m" -eq 0 ] && [ "$d" -ne "$last_day" ]; then
      last_day="$d"
      log "INFO" "到达北京时间 04:00，重启 sing-box"
      kill "$SINGBOX_PID" 2>/dev/null || true
      sleep 2
      start_singbox
    fi
    sleep 5
  done
}

main() {
  section "启动 sing-box-only 脚本"
  log "INFO" "HY2_PORT=$HY2_PORT HTTP_LISTEN_PORT=$HTTP_LISTEN_PORT HY2_SNI=$HY2_SNI TLS_CERT_IP=$TLS_CERT_IP"
  setup_uuid
  setup_download_key
  install_singbox
  setup_cert_and_config
  start_singbox
  print_info
  schedule_restart_loop
}

main "$@"
