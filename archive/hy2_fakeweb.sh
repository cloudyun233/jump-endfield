#!/bin/bash
set -e

# ================== 端口设置 ==================
# HY2 使用 UDP/QUIC；HTTP 伪装站使用 TCP/HTTP。
# 两者可以使用同一个数字端口，因为一个监听 UDP，一个监听 TCP。
export HY2_PORT=${HY2_PORT:-"20164"}
export NGINX_HTTP_PORT=${NGINX_HTTP_PORT:-"${HY2_PORT}"}
export HTTP_LISTEN_PORT=${HTTP_LISTEN_PORT:-"${NGINX_HTTP_PORT}"}

# 启用磁力下载功能后，HTTP 站点必须有后端 API，所以默认强制使用 Node.js HTTP 服务。
export ENABLE_MAGNET_DOWNLOADER=${ENABLE_MAGNET_DOWNLOADER:-"1"}
export NGINX_AUTO_INSTALL=${NGINX_AUTO_INSTALL:-"1"}
export FORCE_NODE_HTTP=${FORCE_NODE_HTTP:-"0"}
if [ "$ENABLE_MAGNET_DOWNLOADER" = "1" ]; then
  export FORCE_NODE_HTTP="1"
fi

# 下载设置：默认只允许同时 1 个活跃磁力任务，避免小容器被打爆。
export DOWNLOAD_MAX_ACTIVE=${DOWNLOAD_MAX_ACTIVE:-"1"}
# 排队设置：默认最多 3 个等待任务，超过后拒绝，避免无限堆积内存和磁盘压力。
export DOWNLOAD_MAX_QUEUE=${DOWNLOAD_MAX_QUEUE:-"3"}
# 下载鉴权：默认自动生成并保存访问密钥，避免公网用户随意提交磁力任务。
# 如确实想完全开放提交，可显式设置 DOWNLOAD_KEY_MODE=none。
export DOWNLOAD_KEY=${DOWNLOAD_KEY:-""}
export DOWNLOAD_KEY_MODE=${DOWNLOAD_KEY_MODE:-"auto"}

# ================== SNI 设置 ==================
export HY2_SNI=${HY2_SNI:-"iroha.cloudyun.qzz.io"}

# ================== 强制切换到脚本所在目录 ==================
cd "$(dirname "$0")"

# ================== 环境变量 & 绝对路径 ==================
export FILE_PATH="${PWD}/.npm/video"
export DATA_PATH="${PWD}/singbox_data"
export NGINX_WEB_ROOT="${FILE_PATH}/nginx_www"
export HTTP_RUNTIME_DIR="${FILE_PATH}/http_runtime"
export NGINX_PREFIX="${HTTP_RUNTIME_DIR}/nginx"
export NODE_SERVER_JS="${HTTP_RUNTIME_DIR}/hy2_video_http_server.mjs"
export NODE_PID_FILE="${HTTP_RUNTIME_DIR}/hy2_video_http_server.pid"
export PYTHON_PID_FILE="${HTTP_RUNTIME_DIR}/hy2_video_python_http.pid"
export DOWNLOAD_DIR="${FILE_PATH}/downloads"
mkdir -p "$FILE_PATH" "$DATA_PATH" "$NGINX_WEB_ROOT/media" "$HTTP_RUNTIME_DIR" "$DOWNLOAD_DIR"

# ================== 下载访问密钥 ==================
DOWNLOAD_KEY_FILE="${FILE_PATH}/download_key.txt"
if [ "${DOWNLOAD_KEY_MODE}" = "none" ]; then
  export DOWNLOAD_KEY=""
elif [ -z "${DOWNLOAD_KEY}" ]; then
  if [ -f "$DOWNLOAD_KEY_FILE" ]; then
    export DOWNLOAD_KEY=$(cat "$DOWNLOAD_KEY_FILE")
    echo -e "\e[1;32m[访问密钥] 已复用本地下载密钥：${DOWNLOAD_KEY_FILE}\e[0m"
  else
    if command -v openssl >/dev/null 2>&1; then
      export DOWNLOAD_KEY=$(openssl rand -hex 16)
    else
      export DOWNLOAD_KEY=$(cat /proc/sys/kernel/random/uuid | tr -d '-')
    fi
    echo "$DOWNLOAD_KEY" > "$DOWNLOAD_KEY_FILE"
    chmod 600 "$DOWNLOAD_KEY_FILE"
    echo -e "\e[1;32m[访问密钥] 已自动生成下载密钥：${DOWNLOAD_KEY}\e[0m"
    echo -e "\e[1;32m[访问密钥] 密钥文件：${DOWNLOAD_KEY_FILE}\e[0m"
  fi
else
  echo -e "\e[1;32m[访问密钥] 已使用环境变量 DOWNLOAD_KEY\e[0m"
fi

HTTP_SERVER_MODE=""
HTTP_SERVER_PID=""

# ================== UUID 固定保存（HY2 密码）==================
UUID_FILE="${FILE_PATH}/uuid.txt"
if [ -f "$UUID_FILE" ]; then
  UUID=$(cat "$UUID_FILE")
  echo -e "\e[1;33m[HY2] 复用固定密码: $UUID\e[0m"
else
  UUID=$(cat /proc/sys/kernel/random/uuid)
  echo "$UUID" > "$UUID_FILE"
  chmod 600 "$UUID_FILE"
  echo -e "\e[1;32m[HY2] 首次生成并永久保存密码: $UUID\e[0m"
fi

# ================== 下载工具 ==================
download_file() {
  local URL=$1
  local FILENAME=$2

  if command -v curl >/dev/null 2>&1; then
    curl -L -sS -o "$FILENAME" "$URL" && echo -e "\e[1;32m下载 $FILENAME (curl)\e[0m"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$FILENAME" "$URL" && echo -e "\e[1;32m下载 $FILENAME (wget)\e[0m"
  else
    echo -e "\e[1;31m未找到 curl 或 wget\e[0m"
    exit 1
  fi
}

fetch_text() {
  local URL=$1

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$URL"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- "$URL"
  else
    echo -e "\e[1;31m未找到 curl 或 wget\e[0m"
    exit 1
  fi
}

fetch_quiet() {
  local URL=$1

  if command -v curl >/dev/null 2>&1; then
    curl -s --max-time 2 "$URL"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- --timeout=2 "$URL"
  else
    return 1
  fi
}

# ================== 通用工具 ==================
human_size() {
  local BYTES=${1:-0}
  awk -v b="$BYTES" 'BEGIN {
    split("B KB MB GB TB PB", u, " ");
    i=1;
    while (b>=1024 && i<6) { b/=1024; i++ }
    if (i==1) printf "%d %s", b, u[i]; else printf "%.2f %s", b, u[i]
  }'
}

html_escape() {
  local s="$1"
  s=${s//&/&amp;}
  s=${s//</&lt;}
  s=${s//>/&gt;}
  s=${s//\"/&quot;}
  s=${s//\'/&#39;}
  printf '%s' "$s"
}

urlencode() {
  local LC_ALL=C
  local s="$1"
  local out=""
  local i c hex
  for ((i=0; i<${#s}; i++)); do
    c=${s:i:1}
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      *) printf -v hex '%%%02X' "'$c"; out+="$hex" ;;
    esac
  done
  printf '%s' "$out"
}

video_mime_type() {
  local name="${1,,}"
  case "$name" in
    *.mp4|*.m4v) printf 'video/mp4' ;;
    *.webm) printf 'video/webm' ;;
    *.mkv) printf 'video/x-matroska' ;;
    *.mov) printf 'video/quicktime' ;;
    *.avi) printf 'video/x-msvideo' ;;
    *.ts) printf 'video/mp2t' ;;
    *.m3u8) printf 'application/vnd.apple.mpegurl' ;;
    *) printf 'application/octet-stream' ;;
  esac
}

# ================== 视频页生成 ==================
collect_video_files() {
  VIDEO_FILES=()
  while IFS= read -r -d '' f; do
    VIDEO_FILES+=("$f")
  done < <(find "$FILE_PATH" -maxdepth 1 -type f \
    \( -iname '*.mp4' -o -iname '*.m4v' -o -iname '*.webm' -o -iname '*.mkv' -o -iname '*.mov' -o -iname '*.avi' -o -iname '*.ts' -o -iname '*.m3u8' \) \
    -print0 | sort -z)
}

sync_video_webroot() {
  mkdir -p "$NGINX_WEB_ROOT/media"
  find "$NGINX_WEB_ROOT/media" -mindepth 1 -maxdepth 1 -type l -delete 2>/dev/null || true

  collect_video_files

  for f in "${VIDEO_FILES[@]}"; do
    [ -f "$f" ] || continue
    ln -sf "$f" "${NGINX_WEB_ROOT}/media/$(basename "$f")"
  done
}

generate_video_page() {
  sync_video_webroot

  local INDEX_FILE="${NGINX_WEB_ROOT}/index.html"
  local COUNT=${#VIDEO_FILES[@]}
  local NOW
  NOW=$(date '+%Y-%m-%d %H:%M:%S')

  cat > "$INDEX_FILE" <<'EOF_HTML_HEAD'
<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>月光放映室</title>
  <style>
    :root {
      color-scheme: dark;
      --bg: #080910;
      --ink: #fff8ec;
      --soft: #d2c2ac;
      --muted: #8f8273;
      --gold: #f0c77b;
      --amber: #d9893d;
      --violet: #7f6df2;
      --card: rgba(255,255,255,.082);
      --card-2: rgba(255,255,255,.13);
      --line: rgba(255,255,255,.16);
      --shadow: rgba(0,0,0,.42);
      --display: "LXGW WenKai Screen", "霞鹜文楷", "STKaiti", "KaiTi", "Songti SC", serif;
      --sans: "HarmonyOS Sans SC", "MiSans", "PingFang SC", "Microsoft YaHei UI", "Microsoft YaHei", system-ui, sans-serif;
      --mono: "Maple Mono", "Cascadia Code", "SFMono-Regular", Consolas, monospace;
    }
    * { box-sizing: border-box; }
    html { height: 100%; }
    body {
      margin: 0;
      color: var(--ink);
      font-family: var(--sans);
      font-size: 15px;
      letter-spacing: .01em;
      background:
        radial-gradient(circle at 14% 4%, rgba(240,199,123,.28), transparent 29rem),
        radial-gradient(circle at 88% 2%, rgba(127,109,242,.22), transparent 31rem),
        radial-gradient(circle at 68% 106%, rgba(217,137,61,.16), transparent 24rem),
        linear-gradient(140deg, #04050a 0%, #0c101a 54%, #17100b 100%);
      height: 100vh;
      height: 100dvh;
      overflow: hidden;
      text-rendering: optimizeLegibility;
      -webkit-font-smoothing: antialiased;
    }
    body::before { content: ""; position: fixed; inset: 0; pointer-events: none; opacity: .22; background-image: linear-gradient(rgba(255,255,255,.055) 1px, transparent 1px), linear-gradient(90deg, rgba(255,255,255,.04) 1px, transparent 1px); background-size: 44px 44px; mask-image: linear-gradient(to bottom, rgba(0,0,0,.9), transparent 76%); }
    a { color: inherit; }
    .wrap { width: min(1260px, calc(100% - 28px)); height: 100vh; height: 100dvh; margin: 0 auto; padding: 15px 0; display: flex; flex-direction: column; gap: 12px; }
    .nav { display: flex; align-items: center; justify-content: space-between; gap: 14px; min-height: 36px; position: relative; z-index: 2; }
    .brand { display: flex; align-items: center; gap: 11px; font-family: var(--display); font-size: 18px; font-weight: 700; letter-spacing: .08em; }
    .logo { width: 34px; height: 34px; display: grid; place-items: center; border-radius: 12px; background: linear-gradient(135deg, rgba(240,199,123,.98), rgba(255,255,255,.22)); color: #120d08; box-shadow: 0 12px 30px rgba(240,199,123,.2); font-family: var(--sans); }
    .navlinks { display: flex; gap: 8px; flex-wrap: wrap; color: var(--soft); font-size: 12px; }
    .navlinks span { border: 1px solid var(--line); border-radius: 999px; padding: 6px 11px; background: rgba(255,255,255,.05); backdrop-filter: blur(12px); }
    .hero { position: relative; overflow: hidden; padding: 22px; border: 1px solid var(--line); border-radius: 26px; background: linear-gradient(120deg, rgba(255,255,255,.135), rgba(255,255,255,.045)), linear-gradient(135deg, rgba(240,199,123,.15), rgba(127,109,242,.1)); box-shadow: 0 20px 62px var(--shadow); backdrop-filter: blur(20px); }
    .hero::after { content: ""; position: absolute; inset: auto -10% -72% 40%; height: 210px; background: radial-gradient(circle, rgba(240,199,123,.24), transparent 62%); pointer-events: none; }
    .eyebrow { margin: 0 0 7px; color: var(--gold); font-family: var(--mono); font-size: 11px; font-weight: 800; letter-spacing: .24em; text-transform: uppercase; }
    h1 { margin: 0; max-width: 780px; font-family: var(--display); font-size: clamp(31px, 4.6vw, 56px); font-weight: 700; line-height: .98; letter-spacing: -.035em; }
    .sub { margin: 10px 0 0; color: var(--soft); font-size: 14px; line-height: 1.75; max-width: 680px; }


    .section-title { display: flex; align-items: end; justify-content: space-between; gap: 12px; margin: 0 3px; }
    .section-title h2 { margin: 0; font-family: var(--display); font-size: 20px; letter-spacing: .01em; }
    .section-title p { margin: 0; color: var(--muted); font-size: 12px; }
    .grid { flex: 1; min-height: 0; display: grid; grid-template-columns: repeat(auto-fill, minmax(220px, 1fr)); align-content: start; gap: 12px; overflow: hidden; }
    .card { min-width: 0; overflow: hidden; border: 1px solid var(--line); border-radius: 18px; background: var(--card); box-shadow: 0 14px 38px rgba(0,0,0,.25); transition: transform .22s ease, border-color .22s ease, background .22s ease, box-shadow .22s ease; }
    .card:hover { transform: translateY(-3px); border-color: rgba(240,199,123,.42); background: var(--card-2); box-shadow: 0 18px 48px rgba(0,0,0,.32); }
    .poster { position: relative; aspect-ratio: 16 / 9; max-height: 154px; display: grid; place-items: center; overflow: hidden; text-decoration: none; background: linear-gradient(135deg, rgba(240,199,123,.2), rgba(127,109,242,.18)), #05070b; color: var(--ink); }
    video { width: 100%; aspect-ratio: 16 / 9; display: block; background: #05070b; object-fit: contain; }
    .poster::before { content: ""; position: absolute; inset: 0; pointer-events: none; background: linear-gradient(180deg, rgba(0,0,0,.04), rgba(0,0,0,.62)); z-index: 1; }
    .poster-mark { position: relative; z-index: 2; width: 48px; height: 48px; display: grid; place-items: center; border-radius: 999px; background: rgba(5,7,11,.62); border: 1px solid rgba(255,255,255,.22); box-shadow: 0 12px 30px rgba(0,0,0,.32); }
    .poster-name { position: absolute; left: 12px; right: 12px; bottom: 10px; z-index: 2; color: rgba(255,248,236,.86); font-size: 12px; font-weight: 800; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .meta { padding: 11px 12px 12px; display: grid; grid-template-columns: minmax(0, 1fr) auto; align-items: center; gap: 8px 10px; }
    .title { margin: 0; font-size: 13px; font-weight: 800; line-height: 1.35; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .info { color: var(--soft); font-family: var(--mono); font-size: 11px; display: flex; gap: 8px; flex-wrap: wrap; grid-column: 1 / -1; }
    .open { display: inline-flex; align-items: center; gap: 6px; text-decoration: none; border: 1px solid rgba(240,199,123,.32); border-radius: 999px; padding: 7px 10px; background: rgba(240,199,123,.12); color: var(--ink); font-family: var(--sans); font-size: 12px; font-weight: 800; cursor: pointer; }
    .empty { flex: 1; min-height: 0; padding: 22px; border: 1px dashed rgba(240,199,123,.28); border-radius: 20px; background: rgba(255,255,255,.055); color: var(--soft); line-height: 1.75; }
    footer { color: rgba(255,248,236,.44); font-family: var(--mono); font-size: 11px; text-align: center; }
    @media (max-width: 640px) {
      .wrap { width: calc(100% - 16px); padding: 8px 0; gap: 8px; }
      .nav { align-items: flex-start; flex-direction: column; gap: 8px; }
      .brand { font-size: 17px; }
      .navlinks { display: none; }
      .hero { padding: 16px; border-radius: 20px; }
      h1 { font-size: clamp(30px, 10vw, 42px); }
      .section-title { align-items: flex-start; flex-direction: column; }
      .grid { grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 8px; }
      .poster { max-height: 120px; }
      .meta { grid-template-columns: 1fr; }
      .open { justify-content: center; }
    }
  </style>
</head>
<body>
  <main class="wrap">
    <nav class="nav" aria-label="站点导航">
      <div class="brand"><span class="logo">▶</span><span>月光放映室</span></div>
      <div class="navlinks"><span>精选</span><span>片库</span><span>稍后观看</span></div>
    </nav>
    <section class="hero">
      <p class="eyebrow">私人片库</p>
      <h1>今晚想看点什么？</h1>
      <p class="sub">浏览已有影片，选择一个标题，就可以在浏览器中直接播放。</p>
EOF_HTML_HEAD

  {
    echo "    </section>"

    if [ "$COUNT" -eq 0 ]; then
      echo "    <section class=\"empty\">"
      echo "      片库正在准备中，新的影片会出现在这里。"
      echo "    </section>"
    else
      echo "    <section id=\"grid\" class=\"grid\">"
      for f in "${VIDEO_FILES[@]}"; do
        [ -f "$f" ] || continue
        base=$(basename "$f")
        title=$(html_escape "$base")
        href="media/$(urlencode "$base")"
        mime=$(video_mime_type "$base")
        bytes=$(stat -c%s "$f" 2>/dev/null || wc -c < "$f")
        size=$(human_size "$bytes")
        mtime=$(date -r "$f" '+%Y-%m-%d %H:%M' 2>/dev/null || echo '-')
        echo "      <article class=\"card\" data-name=\"${title}\">"
        echo "        <video controls preload=\"metadata\"><source src=\"${href}\" type=\"${mime}\"></video>"
        echo "        <div class=\"meta\">"
        echo "          <p class=\"title\">${title}</p>"
        echo "          <div class=\"info\"><span>${size}</span><span>${mtime}</span></div>"
        echo "          <button class=\"open\" type=\"button\" onclick=\"this.closest('article').querySelector('video').play()\">播放</button>"
        echo "        </div>"
        echo "      </article>"
      done
      echo "    </section>"
    fi

    echo "    <footer>月光放映室 · 更新时间 ${NOW}</footer>"
  } >> "$INDEX_FILE"

  cat >> "$INDEX_FILE" <<'EOF_HTML_FOOT'
  </main>


</body>
</html>
EOF_HTML_FOOT

  echo -e "\e[1;32m[HTTP伪装] 视频页面已生成: ${INDEX_FILE}\e[0m"
}

# ================== HTTP 伪装服务：优先 nginx，本地无权限时 fallback 到 Node/Python ==================
try_install_nginx_if_root() {
  if command -v nginx >/dev/null 2>&1; then
    return 0
  fi

  if [ "$NGINX_AUTO_INSTALL" = "0" ]; then
    return 1
  fi

  if [ "$(id -u)" != "0" ]; then
    echo -e "\e[1;33m[Nginx] 未检测到 nginx，且当前不是 root，跳过 apt/yum/apk 安装，改用免安装 HTTP fallback\e[0m"
    return 1
  fi

  echo -e "\e[1;33m[Nginx] 未检测到 nginx，当前是 root，尝试用系统包管理器安装...\e[0m"

  set +e
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y nginx
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y nginx
  elif command -v yum >/dev/null 2>&1; then
    yum install -y nginx
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache nginx
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm nginx
  else
    false
  fi
  local rc=$?
  set -e

  if [ "$rc" -ne 0 ] || ! command -v nginx >/dev/null 2>&1; then
    echo -e "\e[1;33m[Nginx] 自动安装失败，改用免安装 HTTP fallback\e[0m"
    return 1
  fi

  return 0
}

write_nginx_local_conf() {
  mkdir -p "${NGINX_PREFIX}/conf" "${NGINX_PREFIX}/logs" "${NGINX_PREFIX}/client_body_temp" \
           "${NGINX_PREFIX}/proxy_temp" "${NGINX_PREFIX}/fastcgi_temp" "${NGINX_PREFIX}/uwsgi_temp" "${NGINX_PREFIX}/scgi_temp"

  cat > "${NGINX_PREFIX}/conf/nginx.conf" <<EOF_NGINX
worker_processes  1;
error_log  logs/error.log warn;
pid        logs/nginx.pid;

events {
    worker_connections  1024;
}

http {
    default_type application/octet-stream;
    sendfile on;
    tcp_nopush on;
    keepalive_timeout 65;
    access_log off;

    server {
        listen 0.0.0.0:${HTTP_LISTEN_PORT};
        listen [::]:${HTTP_LISTEN_PORT} ipv6only=on;
        server_name _;

        root "${NGINX_WEB_ROOT}";
        index index.html;
        charset utf-8;
        etag on;

        location = / {
            try_files /index.html =404;
        }

        location = /index.html {
            try_files /index.html =404;
        }

        location /media/ {
            types {
                video/mp4 mp4 m4v;
                video/webm webm;
                video/x-matroska mkv;
                video/quicktime mov;
                video/x-msvideo avi;
                video/mp2t ts;
                application/vnd.apple.mpegurl m3u8;
            }
            default_type application/octet-stream;
            add_header Accept-Ranges bytes always;
            add_header X-Content-Type-Options nosniff always;
            try_files \$uri =404;
        }

        location / {
            return 404;
        }
    }
}
EOF_NGINX
}

start_nginx_local() {
  if [ "$FORCE_NODE_HTTP" = "1" ]; then
    return 1
  fi

  try_install_nginx_if_root || return 1
  write_nginx_local_conf

  local CONF_FILE="${NGINX_PREFIX}/conf/nginx.conf"

  set +e
  nginx -p "${NGINX_PREFIX}/" -c "$CONF_FILE" -t >/dev/null 2>&1
  local test_rc=$?
  set -e
  if [ "$test_rc" -ne 0 ]; then
    echo -e "\e[1;33m[Nginx] 本地配置测试失败，改用 HTTP fallback\e[0m"
    return 1
  fi

  if [ -f "${NGINX_PREFIX}/logs/nginx.pid" ]; then
    nginx -p "${NGINX_PREFIX}/" -c "$CONF_FILE" -s quit >/dev/null 2>&1 || true
    sleep 1
  fi

  set +e
  nginx -p "${NGINX_PREFIX}/" -c "$CONF_FILE" >/dev/null 2>&1
  local start_rc=$?
  set -e

  if [ "$start_rc" -ne 0 ]; then
    echo -e "\e[1;33m[Nginx] 启动失败，可能端口已被占用，改用 HTTP fallback\e[0m"
    return 1
  fi

  HTTP_SERVER_MODE="nginx"
  echo -e "\e[1;32m[Nginx] 已以用户态本地配置启动，监听 TCP/HTTP 端口: ${HTTP_LISTEN_PORT}\e[0m"
  echo -e "\e[1;32m[Nginx] 本地配置: ${CONF_FILE}\e[0m"
  return 0
}

write_node_http_server() {
  cat > "$NODE_SERVER_JS" <<'EOF_NODE'
import http from 'node:http';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
import { URL } from 'node:url';

const port = Number(process.env.HTTP_LISTEN_PORT || process.env.NGINX_HTTP_PORT || process.env.HY2_PORT || 20164);
const fileRoot = path.resolve(process.env.FILE_PATH || path.join(process.cwd(), '.npm/video'));
const downloadRoot = path.resolve(process.env.DOWNLOAD_DIR || path.join(fileRoot, 'downloads'));
const maxActive = Math.max(1, Number(process.env.DOWNLOAD_MAX_ACTIVE || 1));
const maxQueued = Math.max(0, Number(process.env.DOWNLOAD_MAX_QUEUE || 3));
const downloadKey = process.env.DOWNLOAD_KEY || '';
const statusCacheMs = Math.max(1000, Number(process.env.STATUS_CACHE_MS || 5000));
const visitorFile = path.join(fileRoot, 'weekly_visitors.json');
let statusCache = null;
let statusCacheAt = 0;
let visitorState = { weekKey: currentWeekKey(), visitors: [] };
let visitorSet = new Set();
let visitorPersistTimer = null;

await fsp.mkdir(downloadRoot, { recursive: true });
await loadVisitorState();

let WebTorrent = null;
let webtorrentLoadError = '';
try {
  const mod = await import('webtorrent');
  WebTorrent = mod.default || mod.WebTorrent || mod;
} catch (err) {
  webtorrentLoadError = err?.message || String(err);
}

const client = WebTorrent ? new WebTorrent({ maxConns: Math.max(12, Number(process.env.DOWNLOAD_MAX_CONNS || 32)) }) : null;
const addedAt = new Map();
const errors = new Map();
const queuedDownloads = [];
const queuedIndex = new Map();
const torrentTasks = new Map();

const videoExts = new Set(['.mp4', '.m4v', '.webm', '.mkv', '.mov', '.avi', '.ts', '.m3u8']);
const skipDirs = new Set(['http_runtime', 'nginx_www', 'node_modules', '.git', '.cache']);

const types = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'application/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.mp4': 'video/mp4',
  '.m4v': 'video/mp4',
  '.webm': 'video/webm',
  '.mkv': 'video/x-matroska',
  '.mov': 'video/quicktime',
  '.avi': 'video/x-msvideo',
  '.ts': 'video/mp2t',
  '.m3u8': 'application/vnd.apple.mpegurl'
};

function human(bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
  let n = Number(bytes || 0);
  let i = 0;
  while (n >= 1024 && i < units.length - 1) { n /= 1024; i++; }
  return i === 0 ? `${n} ${units[i]}` : `${n.toFixed(2)} ${units[i]}`;
}

function escapeHtml(s) {
  return String(s ?? '').replace(/[&<>"']/g, ch => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[ch]));
}

function idFromRel(rel) {
  return Buffer.from(rel, 'utf8').toString('base64url');
}

function relFromId(id) {
  try { return Buffer.from(String(id || ''), 'base64url').toString('utf8'); }
  catch { return ''; }
}

function safeInside(root, target) {
  const r = path.resolve(root);
  const t = path.resolve(target);
  return t === r || t.startsWith(r + path.sep);
}

function currentWeekKey(ts = Date.now()) {
  const d = new Date(ts + 8 * 60 * 60 * 1000);
  const day = d.getUTCDay() || 7;
  d.setUTCDate(d.getUTCDate() - day + 1);
  return d.toISOString().slice(0, 10);
}

async function loadVisitorState() {
  try {
    const data = JSON.parse(await fsp.readFile(visitorFile, 'utf8'));
    if (data?.weekKey === currentWeekKey() && Array.isArray(data.visitors)) {
      visitorState = { weekKey: data.weekKey, visitors: data.visitors.filter(Boolean) };
    }
  } catch {}
  visitorSet = new Set(visitorState.visitors);
  if (visitorState.weekKey !== currentWeekKey()) {
    visitorState = { weekKey: currentWeekKey(), visitors: [] };
    visitorSet = new Set();
    scheduleVisitorPersist();
  }
}

function scheduleVisitorPersist() {
  if (visitorPersistTimer) return;
  visitorPersistTimer = setTimeout(async () => {
    visitorPersistTimer = null;
    const body = JSON.stringify(visitorState);
    const tmp = `${visitorFile}.tmp`;
    try {
      await fsp.writeFile(tmp, body, { mode: 0o600 });
      await fsp.rename(tmp, visitorFile);
    } catch {}
  }, 250);
}

function visitorFingerprint(req) {
  const forwarded = String(req.headers['x-forwarded-for'] || '').split(',')[0].trim();
  const ip = forwarded || req.socket?.remoteAddress || '';
  const ua = String(req.headers['user-agent'] || '');
  return crypto.createHash('sha256').update(`${ip.replace(/^::ffff:/, '')}|${ua}`).digest('hex').slice(0, 24);
}

function recordVisit(req) {
  const weekKey = currentWeekKey();
  if (visitorState.weekKey !== weekKey) {
    visitorState = { weekKey, visitors: [] };
    visitorSet = new Set();
  }
  const id = visitorFingerprint(req);
  if (!visitorSet.has(id)) {
    visitorSet.add(id);
    visitorState.visitors.push(id);
    scheduleVisitorPersist();
    clearStatusCache();
  }
}

function visitorStats() {
  return {
    weekKey: visitorState.weekKey,
    weeklyVisitors: visitorSet.size
  };
}

function hashString(s) {
  let h = 2166136261;
  for (let i = 0; i < String(s).length; i++) {
    h ^= String(s).charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  return h >>> 0;
}

function thumbSvg(name) {
  const h = hashString(name) % 360;
  const h2 = (h + 42) % 360;
  return `<svg xmlns="http://www.w3.org/2000/svg" width="640" height="360" viewBox="0 0 640 360" role="img" aria-label="视频缩略图">
  <defs>
    <linearGradient id="g" x1="0" y1="0" x2="1" y2="1">
      <stop stop-color="hsl(${h} 48% 24%)"/>
      <stop offset="1" stop-color="hsl(${h2} 58% 18%)"/>
    </linearGradient>
  </defs>
  <rect width="640" height="360" fill="url(#g)"/>
  <path d="M0 250C90 214 128 330 229 278C326 228 365 140 461 164C544 185 590 250 640 226V360H0Z" fill="#ffffff" fill-opacity=".08"/>
  <circle cx="320" cy="164" r="54" fill="#000000" fill-opacity=".42" stroke="#ffffff" stroke-opacity=".24" stroke-width="2"/>
  <path d="M306 132v64l50-32z" fill="#fff8ec" fill-opacity=".92"/>
</svg>`;
}

async function walkVideos(dir, base = fileRoot, depth = 0, blockedRels = new Set()) {
  if (depth > 6) return [];
  let entries = [];
  try { entries = await fsp.readdir(dir, { withFileTypes: true }); } catch { return []; }
  const out = [];
  for (const ent of entries) {
    if (ent.name.startsWith('.') && ent.name !== '.npm') continue;
    if (skipDirs.has(ent.name)) continue;
    const full = path.join(dir, ent.name);
    if (!safeInside(fileRoot, full)) continue;
    if (ent.isDirectory()) {
      out.push(...await walkVideos(full, base, depth + 1, blockedRels));
    } else if (ent.isFile() && videoExts.has(path.extname(ent.name).toLowerCase())) {
      try {
        const st = await fsp.stat(full);
        const rel = path.relative(fileRoot, full).split(path.sep).join('/');
        if (blockedRels.has(rel)) continue;
        const ext = path.extname(ent.name).toLowerCase();
        const id = idFromRel(rel);
        out.push({
          id,
          name: ent.name,
          rel,
          size: st.size,
          sizeText: human(st.size),
          mtime: st.mtime.toISOString().slice(0, 16).replace('T', ' '),
          type: types[ext] || 'application/octet-stream',
          url: `/media/${id}`,
          thumbUrl: `/thumb/${id}`
        });
      } catch {}
    }
  }
  return out.sort((a, b) => b.mtime.localeCompare(a.mtime));
}

async function folderBytes(dir, depth = 0) {
  if (depth > 8) return 0;
  let entries = [];
  try { entries = await fsp.readdir(dir, { withFileTypes: true }); } catch { return 0; }
  let total = 0;
  for (const ent of entries) {
    if (skipDirs.has(ent.name)) continue;
    const full = path.join(dir, ent.name);
    if (!safeInside(fileRoot, full)) continue;
    try {
      const st = await fsp.stat(full);
      if (ent.isDirectory()) total += await folderBytes(full, depth + 1);
      else if (ent.isFile()) total += st.size;
    } catch {}
  }
  return total;
}

async function getSpace() {
  let total = 0, free = 0, used = 0, available = 0;
  try {
    const s = await fsp.statfs(fileRoot);
    const bsize = Number(s.bsize || 0);
    total = Number(s.blocks || 0) * bsize;
    free = Number(s.bfree || 0) * bsize;
    available = Number(s.bavail || 0) * bsize;
    used = Math.max(0, total - free);
  } catch {
    const lib = await folderBytes(fileRoot);
    total = 0; free = 0; available = 0; used = lib;
  }
  const libraryBytes = await folderBytes(fileRoot);
  const usedPct = total ? Math.round((used / total) * 1000) / 10 : 0;
  return {
    total, free, available, used, libraryBytes, usedPct,
    totalText: total ? human(total) : '—',
    freeText: free ? human(free) : '—',
    availableText: available ? human(available) : '—',
    usedText: total ? human(used) : human(libraryBytes),
    libraryText: human(libraryBytes)
  };
}

function magnetTaskId(magnet) {
  const m = /xt=urn:btih:([^&]+)/i.exec(String(magnet || ''));
  return (m?.[1] || Buffer.from(String(magnet || '')).toString('base64url').slice(0, 32)).toLowerCase();
}

function createDownloadManager({ maxActive = 1, maxQueued = 3 } = {}) {
  const tasks = [];
  function activeCount() { return tasks.filter(t => t.state === 'downloading').length; }
  function queuedCount() { return tasks.filter(t => t.state === 'queued').length; }
  function startNext() {
    while (activeCount() < maxActive) {
      const next = tasks.find(t => t.state === 'queued');
      if (!next) break;
      next.state = 'downloading';
      next.startedAt = Date.now();
    }
  }
  function enqueue(magnet) {
    if (queuedCount() >= maxQueued && activeCount() >= maxActive) throw new Error(`排队任务已满，最多等待 ${maxQueued} 个`);
    const id = magnetTaskId(magnet);
    if (tasks.some(t => t.id === id && t.state !== 'completed' && t.state !== 'removed')) throw new Error('这个磁力任务已经在下载或排队中');
    const task = { id, magnet, state: 'queued', addedAt: Date.now(), startedAt: 0 };
    tasks.push(task);
    startNext();
    return task;
  }
  function complete(id) {
    const task = tasks.find(t => t.id === id);
    if (task) task.state = 'completed';
    startNext();
  }
  function remove(id) {
    const task = tasks.find(t => t.id === id);
    if (task) task.state = 'removed';
    startNext();
  }
  function visibleTasks() { return tasks.filter(t => t.state !== 'completed' && t.state !== 'removed'); }
  return { enqueue, complete, remove, visibleTasks, activeCount, queuedCount };
}

function queuedView(task) {
  return {
    infoHash: task.id,
    id: task.id,
    name: task.name || `排队任务 ${task.id.slice(0, 8)}`,
    progress: 0,
    downloaded: 0,
    downloadedText: '0 B',
    length: 0,
    lengthText: '等待中',
    downloadSpeed: 0,
    downloadSpeedText: '排队中',
    uploadSpeed: 0,
    peers: 0,
    done: false,
    paused: true,
    state: 'queued',
    addedAt: task.addedAt || Date.now(),
    error: task.error || ''
  };
}

function activeTaskCount() {
  if (!client) return 0;
  return client.torrents.filter(t => !t.done && !t.destroyed).length;
}

function queuedTaskCount() {
  return queuedDownloads.length;
}

function taskTotalCount() {
  return activeTaskCount() + queuedTaskCount();
}

function removeQueuedTask(id) {
  const task = queuedIndex.get(id);
  if (!task) return false;
  queuedIndex.delete(id);
  const idx = queuedDownloads.findIndex(t => t.id === id);
  if (idx >= 0) queuedDownloads.splice(idx, 1);
  return true;
}

function clearStatusCache() {
  statusCache = null;
  statusCacheAt = 0;
}

function cleanupTaskMaps(id) {
  if (!id) return;
  addedAt.delete(id);
  errors.delete(id);
  torrentTasks.delete(id);
  queuedIndex.delete(id);
}

async function removeClientTorrent(torrent, destroyStore = false) {
  if (!client || !torrent) return;
  await new Promise(resolve => client.remove(torrent, { destroyStore }, () => resolve()));
}

async function completeTorrent(torrent) {
  const infoHash = torrent.infoHash || '';
  await removeClientTorrent(torrent, false);
  cleanupTaskMaps(infoHash);
  startQueuedDownloads();
}

function attachTorrentEvents(torrent, fallbackId = '') {
  const task = torrentTasks.get(fallbackId) || torrentTasks.get(torrent.infoHash || '') || null;
  if (task) task.name = torrent.name || task.name;
  const rememberHash = () => {
    const id = torrent.infoHash || fallbackId;
    if (!id) return;
    addedAt.set(id, addedAt.get(fallbackId) || addedAt.get(id) || Date.now());
    if (task) {
      task.id = id;
      task.name = torrent.name || task.name;
      torrentTasks.set(id, task);
    }
  };
  torrent.once('metadata', rememberHash);
  torrent.once('ready', rememberHash);
  torrent.once('done', () => {
    rememberHash();
    completeTorrent(torrent).catch(err => errors.set(torrent.infoHash || fallbackId, err?.message || String(err)));
  });
  torrent.once('error', err => {
    const id = torrent.infoHash || fallbackId;
    errors.set(id, err?.message || String(err));
    removeClientTorrent(torrent, false).finally(() => {
      cleanupTaskMaps(id);
      clearStatusCache();
      startQueuedDownloads();
    });
  });
}

function startQueuedDownloads() {
  if (!client) return;
  while (activeTaskCount() < maxActive && queuedDownloads.length) {
    const task = queuedDownloads.shift();
    queuedIndex.delete(task.id);
    try {
      task.state = 'downloading';
      task.startedAt = Date.now();
      const torrent = client.add(task.magnet, { path: downloadRoot, deselect: false });
      torrentTasks.set(task.id, task);
      if (torrent.infoHash) {
        torrentTasks.set(torrent.infoHash, task);
        addedAt.set(torrent.infoHash, task.addedAt);
      }
      attachTorrentEvents(torrent, task.id);
      clearStatusCache();
    } catch (err) {
      errors.set(task.id, err?.message || String(err));
    }
  }
}
function torrentView(t) {
  const infoHash = t.infoHash || '';
  return {
    infoHash,
    name: t.name || t.dn || (infoHash ? `Import ${infoHash.slice(0, 8)}` : 'Preparing import'),
    progress: Number.isFinite(t.progress) ? Math.round(t.progress * 1000) / 10 : 0,
    downloaded: t.downloaded || 0,
    downloadedText: human(t.downloaded || 0),
    length: t.length || 0,
    lengthText: t.length ? human(t.length) : 'metadata',
    downloadSpeed: t.downloadSpeed || 0,
    downloadSpeedText: `${human(t.downloadSpeed || 0)}/s`,
    uploadSpeed: t.uploadSpeed || 0,
    peers: t.numPeers || 0,
    done: !!t.done,
    paused: !!t.paused,
    addedAt: addedAt.get(infoHash) || Date.now(),
    error: errors.get(infoHash) || ''
  };
}

function activeDownloadVideoRels() {
  const rels = new Set();
  if (!client) return rels;
  for (const torrent of client.torrents) {
    if (torrent.done) continue;
    for (const file of torrent.files || []) {
      const full = path.resolve(downloadRoot, file.path || file.name || '');
      if (!safeInside(fileRoot, full) || !videoExts.has(path.extname(full).toLowerCase())) continue;
      rels.add(path.relative(fileRoot, full).split(path.sep).join('/'));
    }
  }
  return rels;
}

async function statusPayload() {
  const now = Date.now();
  if (statusCache && now - statusCacheAt < statusCacheMs) {
    return { ...statusCache, visitors: visitorStats(), torrents: client ? [...client.torrents.filter(t => !t.done && !t.destroyed).map(torrentView), ...queuedDownloads.map(queuedView)].sort((a, b) => b.addedAt - a.addedAt) : [] };
  }
  const files = await walkVideos(fileRoot, fileRoot, 0, activeDownloadVideoRels());
  const space = await getSpace();
  const torrents = client ? [...client.torrents.filter(t => !t.done && !t.destroyed).map(torrentView), ...queuedDownloads.map(queuedView)].sort((a, b) => b.addedAt - a.addedAt) : [];
  const payload = {
    ok: true,
    site: '月光放映室',
    downloadEnabled: !!client,
    downloadAuthRequired: !!downloadKey,
    downloadError: client ? '' : webtorrentLoadError,
    maxActive,
    maxQueued,
    queued: queuedTaskCount(),
    files,
    space,
    visitors: visitorStats(),
    torrents
  };
  statusCache = payload;
  statusCacheAt = now;
  return payload;
}

function sendJson(res, code, data) {
  const body = JSON.stringify(data);
  res.writeHead(code, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(body),
    'Cache-Control': 'no-store'
  });
  res.end(body);
}

function sendText(res, code, text) {
  res.writeHead(code, { 'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-store' });
  res.end(text);
}

async function readBody(req, limit = 8192) {
  let body = '';
  for await (const chunk of req) {
    body += chunk;
    if (body.length > limit) throw new Error('request body too large');
  }
  return body;
}

function authorized(req) {
  if (!downloadKey) return true;
  const got = req.headers['x-library-key'] || '';
  return got === downloadKey;
}

async function addMagnet(req, res) {
  if (!client) return sendJson(res, 503, { ok: false, error: `下载器不可用：${webtorrentLoadError}` });
  if (!authorized(req)) return sendJson(res, 401, { ok: false, error: '访问密钥不正确或缺失' });

  let data;
  try { data = JSON.parse(await readBody(req)); }
  catch { return sendJson(res, 400, { ok: false, error: '请求格式无效' }); }

  const magnet = String(data?.magnet || '').trim();
  if (!magnet.startsWith('magnet:?') || !/xt=urn:btih:/i.test(magnet) || magnet.length > 8192) {
    return sendJson(res, 400, { ok: false, error: '请输入有效的 BitTorrent 磁力链接' });
  }

  const id = magnetTaskId(magnet);
  if (queuedIndex.has(id) || torrentTasks.has(id) || (client.get(id) && !client.get(id).done)) {
    return sendJson(res, 409, { ok: false, error: '这个磁力任务已经在下载或排队中' });
  }
  if (activeTaskCount() >= maxActive && queuedTaskCount() >= maxQueued) {
    return sendJson(res, 429, { ok: false, error: `排队任务已满，当前最多 ${maxActive} 个下载中、${maxQueued} 个等待中` });
  }

  const task = { id, magnet, state: 'queued', name: `排队任务 ${id.slice(0, 8)}`, addedAt: Date.now(), startedAt: 0 };
  addedAt.set(id, task.addedAt);
  clearStatusCache();
  if (activeTaskCount() < maxActive) {
    try {
      task.state = 'downloading';
      task.startedAt = Date.now();
      const torrent = client.add(magnet, { path: downloadRoot, deselect: false });
      torrentTasks.set(id, task);
      if (torrent.infoHash) {
        torrentTasks.set(torrent.infoHash, task);
        addedAt.set(torrent.infoHash, task.addedAt);
      }
      attachTorrentEvents(torrent, id);
      return sendJson(res, 202, { ok: true, torrent: torrentView(torrent) });
    } catch (err) {
      cleanupTaskMaps(id);
      return sendJson(res, 500, { ok: false, error: err?.message || String(err) });
    }
  }

  queuedDownloads.push(task);
  queuedIndex.set(id, task);
  return sendJson(res, 202, { ok: true, torrent: queuedView(task) });
}

async function removeTorrent(req, res, infoHash) {
  if (!client) return sendJson(res, 503, { ok: false, error: '下载器不可用' });
  if (!authorized(req)) return sendJson(res, 401, { ok: false, error: '访问密钥不正确或缺失' });
  if (removeQueuedTask(infoHash)) {
    clearStatusCache();
    return sendJson(res, 200, { ok: true });
  }
  const t = client.get(infoHash);
  if (!t) return sendJson(res, 404, { ok: false, error: '未找到任务' });
  try {
    await removeClientTorrent(t, false);
    cleanupTaskMaps(infoHash);
    startQueuedDownloads();
    return sendJson(res, 200, { ok: true });
  } catch (err) {
    return sendJson(res, 500, { ok: false, error: err?.message || String(err) });
  }
}

if (process.env.HY2_NODE_SELFTEST === '1') {
  const test = await import('node:test');
  const assert = await import('node:assert/strict');

  test.test('下载队列只启动一个任务且最多允许三个等待任务', () => {
    const manager = createDownloadManager({ maxActive: 1, maxQueued: 3 });
    manager.enqueue('magnet:?xt=urn:btih:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa');
    manager.enqueue('magnet:?xt=urn:btih:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb');
    manager.enqueue('magnet:?xt=urn:btih:cccccccccccccccccccccccccccccccccccccccc');
    manager.enqueue('magnet:?xt=urn:btih:dddddddddddddddddddddddddddddddddddddddd');
    assert.equal(manager.activeCount(), 1);
    assert.equal(manager.queuedCount(), 3);
    assert.throws(() => manager.enqueue('magnet:?xt=urn:btih:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee'), /排队任务已满/);
  });

  test.test('任务完成后从列表消失并启动下一个排队任务', () => {
    const manager = createDownloadManager({ maxActive: 1, maxQueued: 3 });
    const first = manager.enqueue('magnet:?xt=urn:btih:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa');
    const second = manager.enqueue('magnet:?xt=urn:btih:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb');
    manager.complete(first.id);
    const visible = manager.visibleTasks();
    assert.equal(visible.some(t => t.id === first.id), false);
    assert.equal(visible.some(t => t.id === second.id && t.state === 'downloading'), true);
  });
}
function renderPage() {
  return `<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>月光放映室</title>
  <style>
    :root{color-scheme:dark;--ink:#fff8ec;--soft:#d2c2ac;--muted:#8f8273;--gold:#f0c77b;--amber:#d9893d;--violet:#7f6df2;--green:#8ee6bd;--red:#ff9f9f;--card:rgba(255,255,255,.082);--card2:rgba(255,255,255,.13);--line:rgba(255,255,255,.16);--shadow:rgba(0,0,0,.42);--display:"LXGW WenKai Screen","霞鹜文楷","STKaiti","KaiTi","Songti SC",serif;--sans:"HarmonyOS Sans SC","MiSans","PingFang SC","Microsoft YaHei UI","Microsoft YaHei",system-ui,sans-serif;--mono:"Maple Mono","Cascadia Code","SFMono-Regular",Consolas,monospace}
    *{box-sizing:border-box}html,body{min-height:100%}body{margin:0;color:var(--ink);font-family:var(--sans);font-size:15px;letter-spacing:.01em;background:radial-gradient(circle at 14% 4%,rgba(240,199,123,.28),transparent 29rem),radial-gradient(circle at 88% 2%,rgba(127,109,242,.22),transparent 31rem),radial-gradient(circle at 68% 106%,rgba(217,137,61,.16),transparent 24rem),linear-gradient(140deg,#04050a 0%,#0c101a 54%,#17100b 100%);height:100vh;height:100dvh;overflow:hidden;text-rendering:optimizeLegibility;-webkit-font-smoothing:antialiased}body::before{content:"";position:fixed;inset:0;pointer-events:none;opacity:.22;background-image:linear-gradient(rgba(255,255,255,.055) 1px,transparent 1px),linear-gradient(90deg,rgba(255,255,255,.04) 1px,transparent 1px);background-size:44px 44px;mask-image:linear-gradient(to bottom,rgba(0,0,0,.9),transparent 76%)}a{color:inherit}.wrap{width:min(1260px,calc(100% - 28px));height:100vh;height:100dvh;margin:0 auto;padding:14px 0;display:grid;grid-template-rows:auto auto minmax(0,1fr) auto;gap:12px}.nav{display:flex;align-items:center;justify-content:space-between;gap:14px;min-height:36px;position:relative;z-index:2}.brand{display:flex;align-items:center;gap:11px;font-family:var(--display);font-size:18px;font-weight:700;letter-spacing:.08em}.logo{width:34px;height:34px;display:grid;place-items:center;border-radius:12px;background:linear-gradient(135deg,rgba(240,199,123,.98),rgba(255,255,255,.22));color:#120d08;box-shadow:0 12px 30px rgba(240,199,123,.2);font-family:var(--sans)}.navlinks{display:flex;gap:8px;flex-wrap:wrap;color:var(--soft);font-size:12px}.navlinks span{border:1px solid var(--line);border-radius:999px;padding:6px 11px;background:rgba(255,255,255,.05);backdrop-filter:blur(12px)}.hero{position:relative;overflow:hidden;display:grid;grid-template-columns:minmax(0,1fr) minmax(320px,430px);gap:20px;align-items:stretch;padding:22px;border:1px solid var(--line);border-radius:26px;background:linear-gradient(120deg,rgba(255,255,255,.135),rgba(255,255,255,.045)),linear-gradient(135deg,rgba(240,199,123,.15),rgba(127,109,242,.1));box-shadow:0 20px 62px var(--shadow);backdrop-filter:blur(20px)}.hero::after{content:"";position:absolute;inset:auto -10% -72% 40%;height:210px;background:radial-gradient(circle,rgba(240,199,123,.24),transparent 62%);pointer-events:none}.hero-main,.quick-panel{position:relative;z-index:1}.eyebrow{margin:0 0 7px;color:var(--gold);font-family:var(--mono);font-size:11px;font-weight:800;letter-spacing:.24em;text-transform:uppercase}h1{margin:0;max-width:780px;font-family:var(--display);font-size:clamp(31px,4.6vw,56px);font-weight:700;line-height:.98;letter-spacing:-.035em}.sub{margin:10px 0 0;color:var(--soft);font-size:14px;line-height:1.75;max-width:680px}.visit-stat{margin-top:14px;display:inline-flex;align-items:baseline;gap:7px;border:1px solid rgba(240,199,123,.26);border-radius:999px;padding:7px 12px;background:rgba(5,7,11,.24);color:var(--soft);font-size:12px}.visit-stat strong{color:var(--gold);font-family:var(--mono);font-size:18px;line-height:1}.quick-panel{display:grid;gap:12px;padding:14px;border:1px solid rgba(255,255,255,.14);border-radius:20px;background:rgba(5,7,11,.34);box-shadow:inset 0 1px 0 rgba(255,255,255,.06)}.panel-title{display:flex;align-items:center;justify-content:space-between;gap:10px}.panel-title h2{margin:0;font-family:var(--display);font-size:18px}.form{display:grid;grid-template-columns:minmax(0,1fr) auto;gap:8px}.input{width:100%;min-width:0;border:1px solid var(--line);border-radius:14px;background:rgba(255,255,255,.1);color:var(--ink);padding:11px 13px;outline:none;box-shadow:inset 0 1px 0 rgba(255,255,255,.07);font-family:var(--sans)}.input:focus{border-color:rgba(240,199,123,.55);box-shadow:0 0 0 4px rgba(240,199,123,.11),inset 0 1px 0 rgba(255,255,255,.08)}.input::placeholder{color:rgba(255,248,236,.48)}.btn{border:0;border-radius:14px;padding:11px 14px;background:linear-gradient(135deg,var(--gold),var(--amber));color:#1b1108;font-weight:900;cursor:pointer;box-shadow:0 12px 30px rgba(217,137,61,.18)}.btn.secondary{border:1px solid var(--line);background:rgba(255,255,255,.07);color:var(--ink);box-shadow:none}.keyline{display:none}.hint,.msg{margin:0;color:var(--muted);font-size:12px;line-height:1.65}.msg.good{color:var(--green)}.msg.bad{color:var(--red)}.meters{display:grid;gap:8px}.meter-row{display:flex;align-items:center;justify-content:space-between;gap:12px;color:var(--soft);font-size:12px}.meter-row strong{color:var(--ink);font-family:var(--mono);font-size:12px}.bar{height:8px;overflow:hidden;border-radius:999px;background:rgba(255,255,255,.11)}.fill{width:0;height:100%;border-radius:inherit;background:linear-gradient(90deg,var(--violet),var(--gold));transition:width .35s ease}.workspace{min-height:0;display:grid;grid-template-columns:minmax(0,1fr) minmax(260px,340px);gap:12px}.library,.side{min-height:0;display:grid;gap:10px}.library{grid-template-rows:auto minmax(0,1fr)}.side{grid-template-rows:auto minmax(0,1fr)}.section-title{display:flex;align-items:end;justify-content:space-between;gap:12px;margin:0 3px}.section-title h2{margin:0;font-family:var(--display);font-size:20px;letter-spacing:.01em}.section-title p{margin:0;color:var(--muted);font-size:12px}.grid{min-height:0;display:grid;grid-template-columns:repeat(auto-fill,minmax(220px,1fr));align-content:start;gap:12px;overflow:auto;padding-right:2px}.card{min-width:0;overflow:hidden;border:1px solid var(--line);border-radius:18px;background:var(--card);box-shadow:0 14px 38px rgba(0,0,0,.25);transition:transform .22s ease,border-color .22s ease,background .22s ease,box-shadow .22s ease}.card:hover{transform:translateY(-3px);border-color:rgba(240,199,123,.42);background:var(--card2);box-shadow:0 18px 48px rgba(0,0,0,.32)}video{width:100%;aspect-ratio:16/9;max-height:154px;background:#05070b;display:block;object-fit:contain}.poster{position:relative;aspect-ratio:16/9;max-height:154px;display:block;overflow:hidden;background:#05070b;text-decoration:none}.poster:before{content:"";position:absolute;inset:0;z-index:1;background:linear-gradient(180deg,rgba(0,0,0,.03),rgba(0,0,0,.62));pointer-events:none}.thumb{width:100%;height:100%;display:block;object-fit:cover}.poster-play{position:absolute;z-index:2;left:50%;top:50%;width:48px;height:48px;display:grid;place-items:center;transform:translate(-50%,-50%);border-radius:999px;border:1px solid rgba(255,255,255,.22);background:rgba(5,7,11,.62);box-shadow:0 12px 30px rgba(0,0,0,.32)}.poster-name{position:absolute;z-index:2;left:12px;right:12px;bottom:10px;color:rgba(255,248,236,.86);font-size:12px;font-weight:800;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.meta{padding:11px 12px 12px;display:grid;grid-template-columns:minmax(0,1fr) auto;align-items:center;gap:8px 10px}.title{margin:0;font-size:13px;font-weight:800;line-height:1.35;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.info{color:var(--soft);font-family:var(--mono);font-size:11px;display:flex;gap:8px;flex-wrap:wrap;grid-column:1/-1}.open{display:inline-flex;align-items:center;gap:6px;text-decoration:none;border:1px solid rgba(240,199,123,.32);border-radius:999px;padding:7px 10px;background:rgba(240,199,123,.12);color:var(--ink);font-size:12px;font-weight:800}.tasks{min-height:0;overflow:auto;display:grid;align-content:start;gap:10px}.task{border:1px solid var(--line);border-radius:16px;background:rgba(255,255,255,.07);padding:12px}.task-top{display:grid;grid-template-columns:minmax(0,1fr) auto;gap:10px;align-items:start}.task-name{font-weight:900;line-height:1.35;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.task-meta{margin-top:5px;color:var(--soft);font-family:var(--mono);font-size:11px;display:flex;gap:8px;flex-wrap:wrap}.empty{min-height:0;padding:22px;border:1px dashed rgba(240,199,123,.28);border-radius:20px;background:rgba(255,255,255,.055);color:var(--soft);line-height:1.75}footer{color:rgba(255,248,236,.44);font-family:var(--mono);font-size:11px;text-align:center}@media (max-width:900px){body{height:auto;min-height:100vh;overflow:auto}.wrap{width:min(100% - 18px,760px);height:auto;min-height:100vh;grid-template-rows:auto auto auto auto;padding:10px 0}.hero,.workspace{grid-template-columns:1fr}.side{grid-template-rows:auto}.grid,.tasks{overflow:visible}.quick-panel{gap:10px}}@media (max-width:640px){body{font-size:14px}.wrap{width:calc(100% - 14px);gap:9px}.nav{align-items:flex-start;flex-direction:column;gap:8px}.brand{font-size:17px}.navlinks{display:none}.hero{padding:15px;border-radius:20px}.sub{font-size:13px}.visit-stat{margin-top:12px}.quick-panel{padding:12px;border-radius:17px}.panel-title{align-items:flex-start;flex-direction:column}.form{grid-template-columns:1fr}.btn{width:100%;min-height:42px}.grid{grid-template-columns:1fr;gap:10px}video,.poster{max-height:none}.meta{grid-template-columns:1fr}.open{justify-content:center}.task-top{grid-template-columns:1fr}.task .btn{width:100%}}
    .open{font-family:var(--sans);cursor:pointer}.media-player{width:100%;aspect-ratio:16/9;max-height:none;background:#05070b;display:block;object-fit:contain}
  </style>
</head>
<body>
  <main class="wrap">
    <nav class="nav" aria-label="站点导航"><div class="brand"><span class="logo">▶</span><span>月光放映室</span></div><div class="navlinks"><span>精选</span><span>片库</span><span>导入</span></div></nav>
    <section class="hero">
      <div class="hero-main"><p class="eyebrow">私人片库</p><h1>今晚想看点什么？</h1><p class="sub">浏览已有影片，也可以直接导入新的磁力任务。下载完成后，影片会自动出现在片库中。</p><div class="visit-stat"><span>本周已访问</span><strong id="visitorCount">—</strong><span>人</span></div></div>
      <div class="quick-panel">
        <div class="panel-title"><h2>导入影片</h2><span class="hint">磁力任务</span></div>
        <div class="form"><input id="magnet" class="input" placeholder="粘贴 magnet 磁力链接" autocomplete="off"><button id="add" class="btn">开始导入</button></div>
        <div id="keyline" class="keyline"><input id="key" class="input" placeholder="访问密钥" autocomplete="off"></div>
        <div class="meters"><div class="meter-row"><span>已用空间</span><strong id="used">—</strong></div><div class="bar"><div class="fill" id="spacebar"></div></div><div class="meter-row"><span>可用空间</span><strong id="free">—</strong></div><div class="meter-row"><span>片库占用</span><strong id="libsize">—</strong></div></div>
        <p class="hint">可播放的视频文件会自动出现在片库中，下载进度会实时刷新。</p><div id="msg" class="msg"></div>
      </div>
    </section>
    <section class="workspace">
      <section class="library"><div class="section-title"><div><h2>正在放映</h2><p>可播放影片</p></div></div><section id="grid" class="grid"><div class="empty">片库正在准备中，新的影片会出现在这里。</div></section></section>
      <aside class="side"><div class="section-title"><div><h2>下载任务</h2><p>实时传输进度</p></div></div><section id="tasks" class="tasks"><div class="empty">暂无下载任务。</div></section></aside>
    </section>
    <footer>月光放映室</footer>
  </main>
<script>
const $ = s => document.querySelector(s);
const grid = $('#grid'), tasks = $('#tasks'), msg = $('#msg');
let authRequired = false;
let lastFilesSig = '';
function esc(s){return String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));}
function setMsg(text, cls=''){msg.textContent=text||'';msg.className='msg '+cls;}
function taskHtml(t){return '<article class="task"><div class="task-top"><div><div class="task-name">'+esc(t.name)+'</div><div class="task-meta"><span>'+esc(t.downloadedText)+' / '+esc(t.lengthText)+'</span><span>'+esc(t.downloadSpeedText)+'</span><span>'+esc(t.peers)+' 个连接</span></div></div><button class="btn secondary" data-remove="'+esc(t.infoHash)+'">移除</button></div><div class="bar"><div class="fill" style="width:'+Math.max(0,Math.min(100,t.progress))+'%"></div></div></article>';}
function fileHtml(f){return '<article class="card"><video class="media-player" controls preload="metadata" poster="'+esc(f.thumbUrl)+'"><source src="'+esc(f.url)+'" type="'+esc(f.type)+'"></video><div class="meta"><p class="title">'+esc(f.name)+'</p><div class="info"><span>'+esc(f.sizeText)+'</span><span>'+esc(f.mtime)+'</span></div><button class="open" type="button" data-play="'+esc(f.id)+'">播放</button></div></article>';}
function videoBusy(){return [...grid.querySelectorAll('video')].some(v=>!v.paused&&!v.ended);}
function renderFiles(files){
  const sig = files.map(f=>f.id+':'+f.size+':'+f.mtime).join('|');
  if (sig === lastFilesSig) return;
  if (videoBusy()) return;
  lastFilesSig = sig;
  grid.innerHTML = files.length ? files.map(fileHtml).join('') : '<div class="empty">片库正在准备中，新的影片会出现在这里。</div>';
}
async function refresh(){
  const r = await fetch('/api/status', {cache:'no-store'}); const d = await r.json();
  authRequired = !!d.downloadAuthRequired; $('#keyline').style.display = authRequired ? 'block' : 'none';
  $('#used').textContent = d.space.usedText + (d.space.totalText !== '—' ? ' / ' + d.space.totalText : '');
  $('#free').textContent = d.space.availableText || d.space.freeText;
  $('#libsize').textContent = d.space.libraryText;
  $('#spacebar').style.width = Math.max(0, Math.min(100, d.space.usedPct || 0)) + '%';
  $('#visitorCount').textContent = d.visitors?.weeklyVisitors ?? '—';
  const active = d.torrents || [];
  tasks.innerHTML = active.length ? active.map(taskHtml).join('') : '<div class="empty">暂无下载任务。</div>';
  renderFiles(d.files || []);
  if (!d.downloadEnabled) setMsg('下载器在此服务器不可用。', 'bad');
}
$('#add').addEventListener('click', async()=>{
  const magnet = $('#magnet').value.trim(); if(!magnet){setMsg('请先粘贴磁力链接。', 'bad'); return;}
  setMsg('正在创建下载任务...', '');
  const headers = {'Content-Type':'application/json'}; if(authRequired) headers['X-Library-Key']=$('#key').value.trim();
  const r = await fetch('/api/downloads', {method:'POST', headers, body:JSON.stringify({magnet})}); const d = await r.json().catch(()=>({ok:false,error:'请求失败'}));
  if(!d.ok){setMsg(d.error || '导入失败。', 'bad'); return;}
  $('#magnet').value=''; setMsg('下载任务已创建。', 'good'); refresh();
});
tasks.addEventListener('click', async(e)=>{
  const id = e.target?.dataset?.remove; if(!id) return;
  const headers = {}; if(authRequired) headers['X-Library-Key']=$('#key').value.trim();
  await fetch('/api/downloads/'+encodeURIComponent(id), {method:'DELETE', headers}); refresh();
});
grid.addEventListener('click', e=>{
  const id = e.target?.dataset?.play; if(!id) return;
  const video = e.target.closest('.card')?.querySelector('video');
  if(video) video.play().catch(()=>setMsg('浏览器无法直接播放这个视频格式。', 'bad'));
});
grid.addEventListener('play', e=>{if(e.target?.tagName==='VIDEO'){grid.querySelectorAll('video').forEach(v=>{if(v!==e.target)v.pause();});}}, true);
refresh(); setInterval(refresh, 5000);
</script>
</body>
</html>`;
}
function serveThumb(req, res, id) {
  const rel = relFromId(id);
  if (!rel || rel.includes('\0')) return sendText(res, 403, 'Forbidden');
  const filePath = path.resolve(fileRoot, rel);
  if (!safeInside(fileRoot, filePath) || !videoExts.has(path.extname(filePath).toLowerCase())) return sendText(res, 403, 'Forbidden');
  fs.stat(filePath, (err, stat) => {
    if (err || !stat.isFile()) return sendText(res, 404, '404 Not Found');
    const body = thumbSvg(path.basename(filePath));
    res.writeHead(200, {
      'Content-Type': 'image/svg+xml; charset=utf-8',
      'Content-Length': Buffer.byteLength(body),
      'Cache-Control': 'public, max-age=3600',
      'X-Content-Type-Options': 'nosniff'
    });
    if (req.method === 'HEAD') return res.end();
    res.end(body);
  });
}
function serveMedia(req, res, id) {
  const rel = relFromId(id);
  if (!rel || rel.includes('\0')) return sendText(res, 403, 'Forbidden');
  const filePath = path.resolve(fileRoot, rel);
  if (!safeInside(fileRoot, filePath)) return sendText(res, 403, 'Forbidden');
  fs.stat(filePath, (err, stat) => {
    if (err || !stat.isFile()) return sendText(res, 404, '404 Not Found');
    const ext = path.extname(filePath).toLowerCase();
    const contentType = types[ext] || 'application/octet-stream';
    const total = stat.size;
    const range = req.headers.range;
    const headOnly = req.method === 'HEAD';
    const commonHeaders = { 'Content-Type': contentType, 'Accept-Ranges': 'bytes', 'X-Content-Type-Options': 'nosniff', 'Cache-Control': 'public, max-age=1800' };
    if (range) {
      const match = /^bytes=(\d*)-(\d*)$/.exec(range);
      if (!match) { res.writeHead(416, { ...commonHeaders, 'Content-Range': `bytes */${total}` }); return res.end(); }
      let start;
      let end;
      if (match[1] === '') {
        const suffix = Number(match[2]);
        if (!Number.isFinite(suffix) || suffix <= 0) { res.writeHead(416, { ...commonHeaders, 'Content-Range': `bytes */${total}` }); return res.end(); }
        start = Math.max(total - suffix, 0);
        end = total - 1;
      } else {
        start = Number(match[1]);
        end = match[2] === '' ? total - 1 : Number(match[2]);
      }
      if (Number.isNaN(start) || Number.isNaN(end) || start > end || start >= total) { res.writeHead(416, { ...commonHeaders, 'Content-Range': `bytes */${total}` }); return res.end(); }
      end = Math.min(end, total - 1);
      res.writeHead(206, { ...commonHeaders, 'Content-Range': `bytes ${start}-${end}/${total}`, 'Content-Length': end - start + 1 });
      if (headOnly) return res.end();
      return fs.createReadStream(filePath, { start, end }).pipe(res);
    }
    res.writeHead(200, { ...commonHeaders, 'Content-Length': total });
    if (headOnly) return res.end();
    fs.createReadStream(filePath).pipe(res);
  });
}

const server = http.createServer(async (req, res) => {
  let pathname = '/';
  try { pathname = new URL(req.url, 'http://127.0.0.1').pathname; }
  catch { return sendText(res, 400, 'Bad Request'); }

  try {
    if (req.method === 'GET' && (pathname === '/' || pathname === '/index.html')) {
      recordVisit(req);
      const html = renderPage();
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Content-Length': Buffer.byteLength(html), 'Cache-Control': 'no-cache' });
      return res.end(html);
    }
    if (req.method === 'GET' && pathname === '/api/status') return sendJson(res, 200, await statusPayload());
    if (req.method === 'POST' && pathname === '/api/downloads') return addMagnet(req, res);
    if (req.method === 'DELETE' && pathname.startsWith('/api/downloads/')) return removeTorrent(req, res, decodeURIComponent(pathname.slice('/api/downloads/'.length)));
    if ((req.method === 'GET' || req.method === 'HEAD') && pathname.startsWith('/thumb/')) return serveThumb(req, res, decodeURIComponent(pathname.slice('/thumb/'.length)));
    if ((req.method === 'GET' || req.method === 'HEAD') && pathname.startsWith('/media/')) return serveMedia(req, res, decodeURIComponent(pathname.slice('/media/'.length)));
    return sendText(res, 404, '404 Not Found');
  } catch (err) {
    return sendJson(res, 500, { ok: false, error: err?.message || String(err) });
  }
});

function listen(host) {
  server.listen(port, host, () => {
    console.log(`[Node HTTP] listening on ${host}:${port}, root=${fileRoot}, downloads=${downloadRoot}, downloader=${client ? 'webtorrent' : 'unavailable'}`);
  });
}

server.on('error', (err) => {
  if (err.code === 'EADDRNOTAVAIL' || err.code === 'EAFNOSUPPORT') {
    console.error(`[Node HTTP] ${err.code} on ::, retrying 0.0.0.0`);
    try { server.close(() => listen('0.0.0.0')); } catch { listen('0.0.0.0'); }
    return;
  }
  console.error(err);
  process.exit(1);
});

listen('::');
EOF_NODE
}

stop_pid_file() {
  local pid_file="$1"
  if [ -f "$pid_file" ]; then
    local old_pid
    old_pid=$(cat "$pid_file" 2>/dev/null || true)
    if [ -n "$old_pid" ]; then
      kill "$old_pid" 2>/dev/null || true
      sleep 1
    fi
    rm -f "$pid_file"
  fi
}

ensure_webtorrent_module() {
  if [ "$ENABLE_MAGNET_DOWNLOADER" != "1" ]; then
    return 0
  fi

  if ! command -v npm >/dev/null 2>&1; then
    echo -e "\e[1;33m[WebTorrent] 未检测到 npm，下载功能不可用，但网页仍可启动\e[0m"
    return 0
  fi

  if [ -d "${HTTP_RUNTIME_DIR}/node_modules/webtorrent" ]; then
    echo -e "\e[1;32m[WebTorrent] 本地模块已存在\e[0m"
    return 0
  fi

  echo -e "\e[1;33m[WebTorrent] 首次启用磁力下载，正在安装本地 npm 模块 webtorrent...\e[0m"
  cat > "${HTTP_RUNTIME_DIR}/package.json" <<'EOF_PACKAGE'
{
  "private": true,
  "type": "module",
  "dependencies": {
    "webtorrent": "latest"
  }
}
EOF_PACKAGE

  set +e
  (cd "$HTTP_RUNTIME_DIR" && npm install --omit=dev --no-audit --no-fund --loglevel=error)
  local rc=$?
  set -e

  if [ "$rc" -ne 0 ]; then
    echo -e "\e[1;33m[WebTorrent] npm 安装失败，下载功能会显示不可用；可检查网络或手动执行：cd ${HTTP_RUNTIME_DIR} && npm install --omit=dev --no-audit --no-fund --loglevel=error\e[0m"
  else
    echo -e "\e[1;32m[WebTorrent] 安装完成\e[0m"
  fi
}

start_node_http_server() {
  if ! command -v node >/dev/null 2>&1; then
    return 1
  fi

  ensure_webtorrent_module
  write_node_http_server
  stop_pid_file "$NODE_PID_FILE"

  node "$NODE_SERVER_JS" > "${HTTP_RUNTIME_DIR}/node_http.log" 2>&1 &
  HTTP_SERVER_PID=$!
  echo "$HTTP_SERVER_PID" > "$NODE_PID_FILE"
  sleep 1

  if ! kill -0 "$HTTP_SERVER_PID" 2>/dev/null; then
    echo -e "\e[1;33m[Node HTTP] 启动失败，日志如下：\e[0m"
    tail -n 50 "${HTTP_RUNTIME_DIR}/node_http.log" 2>/dev/null || true
    return 1
  fi

  HTTP_SERVER_MODE="node"
  echo -e "\e[1;32m[Node HTTP] 已启动媒体库与下载后端，监听 TCP/HTTP 端口: ${HTTP_LISTEN_PORT}\e[0m"
  echo -e "\e[1;32m[Node HTTP] 日志: ${HTTP_RUNTIME_DIR}/node_http.log\e[0m"
  if [ "$ENABLE_MAGNET_DOWNLOADER" = "1" ]; then
    echo -e "\e[1;32m[下载目录] ${DOWNLOAD_DIR}\e[0m"
    echo -e "\e[1;32m[并发限制] DOWNLOAD_MAX_ACTIVE=${DOWNLOAD_MAX_ACTIVE}, DOWNLOAD_MAX_QUEUE=${DOWNLOAD_MAX_QUEUE}\e[0m"
    if [ -n "$DOWNLOAD_KEY" ]; then
      echo -e "\e[1;32m[访问密钥] 已启用 DOWNLOAD_KEY，网页导入时需要填写\e[0m"
    else
      echo -e "\e[1;33m[访问密钥] DOWNLOAD_KEY_MODE=none，公网访问者可提交磁力链接（不建议）\e[0m"
    fi
  fi
  return 0
}

start_python_http_server() {
  if ! command -v python3 >/dev/null 2>&1; then
    return 1
  fi

  stop_pid_file "$PYTHON_PID_FILE"

  (cd "$NGINX_WEB_ROOT" && python3 -m http.server "$HTTP_LISTEN_PORT" --bind 0.0.0.0) > "${HTTP_RUNTIME_DIR}/python_http.log" 2>&1 &
  HTTP_SERVER_PID=$!
  echo "$HTTP_SERVER_PID" > "$PYTHON_PID_FILE"
  sleep 1

  if ! kill -0 "$HTTP_SERVER_PID" 2>/dev/null; then
    echo -e "\e[1;33m[Python HTTP] 启动失败，日志如下：\e[0m"
    tail -n 30 "${HTTP_RUNTIME_DIR}/python_http.log" 2>/dev/null || true
    return 1
  fi

  HTTP_SERVER_MODE="python"
  echo -e "\e[1;32m[Python HTTP] 已启动免安装伪装站，监听 TCP/HTTP 端口: ${HTTP_LISTEN_PORT}\e[0m"
  echo -e "\e[1;33m[Python HTTP] 注意：Python fallback 可用，但视频 Range 支持可能不如 Nginx/Node 完整\e[0m"
  return 0
}

start_http_masquerade_server() {
  generate_video_page

  if [ "$ENABLE_MAGNET_DOWNLOADER" = "1" ]; then
    if start_node_http_server; then
      return 0
    fi
    echo -e "\e[1;31m[HTTP伪装] 启动失败：启用磁力下载需要 Node.js 后端，但 Node 服务无法启动\e[0m"
    exit 1
  fi

  if start_nginx_local; then
    return 0
  fi

  if start_node_http_server; then
    return 0
  fi

  if start_python_http_server; then
    return 0
  fi

  echo -e "\e[1;31m[HTTP伪装] 启动失败：无 nginx、无 node、无 python3，无法提供伪装网页\e[0m"
  exit 1
}

reload_http_masquerade_server() {
  generate_video_page

  if [ "$HTTP_SERVER_MODE" = "nginx" ]; then
    nginx -p "${NGINX_PREFIX}/" -c "${NGINX_PREFIX}/conf/nginx.conf" -s reload >/dev/null 2>&1 || true
  fi
}

# ================== 架构检测 & 安装/更新 sing-box ==================
# 固定使用 ${FILE_PATH}/sing-box。
# 启动时会先尝试把旧版随机 6 位文件名的 sing-box 迁移成固定文件名，
# 再清理剩余旧随机二进制，避免 .npm/video 目录持续膨胀。
export SINGBOX_AUTO_UPDATE=${SINGBOX_AUTO_UPDATE:-"1"}
export SINGBOX_BIN="${SINGBOX_BIN:-${FILE_PATH}/sing-box}"
export SINGBOX_VERSION_FILE="${FILE_PATH}/sing-box.version"
export SINGBOX_TMP_DIR="${FILE_PATH}/.singbox_tmp"
# 首次安装或更新时需要同时容纳压缩包和解压后的二进制；空间太小时直接给出明确错误。
export SINGBOX_MIN_FREE_MB=${SINGBOX_MIN_FREE_MB:-"120"}

ARCH=$(uname -m)

case "$ARCH" in
  x86_64|amd64)
    SB_ARCH="amd64"
    ;;
  aarch64|arm64)
    SB_ARCH="arm64"
    ;;
  armv7l|armv7)
    SB_ARCH="armv7"
    ;;
  armv6l|armv6)
    SB_ARCH="armv6"
    ;;
  s390x)
    SB_ARCH="s390x"
    ;;
  *)
    echo "不支持的架构: $ARCH"
    exit 1
    ;;
esac

get_singbox_version() {
  local bin="$1"
  [ -x "$bin" ] || return 1
  "$bin" version 2>/dev/null | grep -m1 -Eo '([0-9]+\.){2}[0-9]+([^[:space:]]*)?' || return 1
}

is_singbox_binary() {
  local bin="$1"
  [ -x "$bin" ] || return 1
  "$bin" version 2>/dev/null | head -n 3 | grep -qi 'sing-box'
}

free_space_mb() {
  # 输出目标路径所在文件系统的可用空间，单位 MiB。
  local target="$1"
  df -Pm "$target" 2>/dev/null | awk 'NR==2 {print $4}'
}

print_space_hint() {
  echo -e "\e[1;33m[空间诊断] 当前目录占用最大的项目：\e[0m"
  du -sh "${FILE_PATH}"/* "${FILE_PATH}"/.[!.]* 2>/dev/null | sort -hr | head -n 12 || true
  echo -e "\e[1;33m[空间诊断] 文件系统空间：\e[0m"
  df -h "$FILE_PATH" 2>/dev/null || true
  echo -e "\e[1;33m[空间诊断] inode 使用情况：\e[0m"
  df -ih "$FILE_PATH" 2>/dev/null || true
}

require_free_space_for_singbox_install() {
  local available
  available=$(free_space_mb "$FILE_PATH" || echo "")
  if [ -n "$available" ] && [ "$available" -lt "$SINGBOX_MIN_FREE_MB" ]; then
    echo -e "\e[1;31m[sing-box] 可用空间不足：${available}MiB，安装/更新至少建议 ${SINGBOX_MIN_FREE_MB}MiB\e[0m"
    echo -e "\e[1;31m[sing-box] 为避免再次写爆容器，已停止下载。请先删除旧随机二进制、无用视频或 downloads 里的大文件。\e[0m"
    print_space_hint
    exit 1
  fi
}

cleanup_failed_singbox_install_leftovers() {
  # 清理上次失败安装留下的固定临时文件和脚本专用临时目录。
  rm -f "${SINGBOX_BIN}.new" "${SINGBOX_BIN}.tmp" 2>/dev/null || true
  rm -rf "$SINGBOX_TMP_DIR" 2>/dev/null || true

  # 旧版本曾用 /tmp/tmp.xxxxxx；如果中途 cp/mv 失败，目录可能残留并持续占空间。
  # 只删除包含 sing-box release 包或 sing-box.new 的临时目录，避免误删别的程序临时文件。
  local tmp_base d
  tmp_base="${TMPDIR:-/tmp}"
  if [ -d "$tmp_base" ]; then
    while IFS= read -r -d '' d; do
      if find "$d" -maxdepth 1 \( -name 'sing-box-*-linux-*.tar.gz' -o -name 'sing-box.new' \) -print -quit 2>/dev/null | grep -q .; then
        rm -rf "$d" 2>/dev/null || true
      fi
    done < <(find "$tmp_base" -maxdepth 1 -type d -name 'tmp.*' -print0 2>/dev/null)
  fi
}

find_old_random_singbox_bin() {
  # 找旧脚本生成的 6 位小写/数字随机名 sing-box 二进制。
  local f base
  while IFS= read -r -d '' f; do
    [ "$f" = "$SINGBOX_BIN" ] && continue
    base=$(basename "$f")
    [ "${#base}" -eq 6 ] || continue
    case "$base" in
      *[!a-z0-9]*) continue ;;
    esac
    if is_singbox_binary "$f"; then
      printf '%s\n' "$f"
      return 0
    fi
  done < <(find "$FILE_PATH" -maxdepth 1 -type f -print0 2>/dev/null)
  return 1
}

promote_old_random_singbox_if_needed() {
  # 如果固定文件不存在，但目录里还有旧随机 sing-box，直接重命名复用，避免无空间时还去重新下载。
  local candidate version
  if [ -x "$SINGBOX_BIN" ] && is_singbox_binary "$SINGBOX_BIN"; then
    return 0
  fi

  candidate=$(find_old_random_singbox_bin || true)
  if [ -n "$candidate" ]; then
    version=$(get_singbox_version "$candidate" || true)
    mv -f "$candidate" "$SINGBOX_BIN"
    chmod +x "$SINGBOX_BIN"
    [ -n "$version" ] && echo "$version" > "$SINGBOX_VERSION_FILE"
    echo -e "\e[1;32m[sing-box] 已把旧随机二进制迁移为固定文件: $(basename "$candidate") -> ${SINGBOX_BIN}\e[0m"
  fi
}

cleanup_old_random_singbox_bins() {
  # 清理剩余旧脚本生成的 6 位小写/数字随机名，并且必须能执行出 sing-box version，避免误删视频或用户文件。
  local f base removed=0
  while IFS= read -r -d '' f; do
    [ "$f" = "$SINGBOX_BIN" ] && continue
    base=$(basename "$f")
    [ "${#base}" -eq 6 ] || continue
    case "$base" in
      *[!a-z0-9]*) continue ;;
    esac
    if is_singbox_binary "$f"; then
      rm -f "$f" && removed=$((removed + 1))
    fi
  done < <(find "$FILE_PATH" -maxdepth 1 -type f -print0 2>/dev/null)

  if [ "$removed" -gt 0 ]; then
    echo -e "\e[1;32m[sing-box] 已清理旧随机二进制文件: ${removed} 个\e[0m"
  fi
}

install_singbox_version() {
  local version="$1"
  local tarball="sing-box-${version}-linux-${SB_ARCH}.tar.gz"
  local download_url="https://github.com/SagerNet/sing-box/releases/download/v${version}/${tarball}"
  local archive_path singbox_src new_bin

  require_free_space_for_singbox_install

  rm -rf "$SINGBOX_TMP_DIR"
  mkdir -p "$SINGBOX_TMP_DIR"
  archive_path="${SINGBOX_TMP_DIR}/${tarball}"
  new_bin="${SINGBOX_BIN}.new"

  # 确保即使下载、解压或移动中途失败，也会清理临时目录，避免下次启动空间更少。
  cleanup_on_install_fail() {
    rm -rf "$SINGBOX_TMP_DIR" 2>/dev/null || true
    rm -f "$new_bin" 2>/dev/null || true
  }
  trap cleanup_on_install_fail RETURN

  download_file "$download_url" "$archive_path"
  tar -xzf "$archive_path" -C "$SINGBOX_TMP_DIR"

  singbox_src=$(find "$SINGBOX_TMP_DIR" -type f -name "sing-box" | head -n 1)
  if [ -z "$singbox_src" ]; then
    echo -e "\e[1;31m未在压缩包中找到 sing-box 二进制文件\e[0m"
    exit 1
  fi

  # 不再在 /tmp 内 cp 出第二份 sing-box.new；直接移动到最终目录旁边，再原子替换。
  mv -f "$singbox_src" "$new_bin"
  chmod +x "$new_bin"

  mv -f "$new_bin" "$SINGBOX_BIN"
  chmod +x "$SINGBOX_BIN"
  echo "$version" > "$SINGBOX_VERSION_FILE"
  rm -rf "$SINGBOX_TMP_DIR"
  trap - RETURN

  echo -e "\e[1;32m[sing-box] 已安装/更新到固定路径: $SINGBOX_BIN\e[0m"
}

ensure_singbox() {
  local current_version latest_json latest_version path_singbox

  cleanup_failed_singbox_install_leftovers
  promote_old_random_singbox_if_needed
  cleanup_old_random_singbox_bins

  current_version=$(get_singbox_version "$SINGBOX_BIN" || true)
  if [ -n "$current_version" ]; then
    echo -e "\e[1;32m[sing-box] 检测到已安装版本: v${current_version}\e[0m"
  else
    # 如果系统 PATH 里已经有 sing-box，也允许复用，避免小容器里重复下载。
    path_singbox=$(command -v sing-box 2>/dev/null || true)
    if [ -n "$path_singbox" ] && is_singbox_binary "$path_singbox"; then
      export SINGBOX_BIN="$path_singbox"
      current_version=$(get_singbox_version "$SINGBOX_BIN" || true)
      echo -e "\e[1;32m[sing-box] 复用系统 PATH 中的 sing-box: ${SINGBOX_BIN} v${current_version}\e[0m"
    else
      echo -e "\e[1;33m[sing-box] 未检测到可用的固定安装文件: $SINGBOX_BIN\e[0m"
    fi
  fi

  if [ "$SINGBOX_AUTO_UPDATE" != "1" ] && [ -n "$current_version" ]; then
    echo -e "\e[1;33m[sing-box] SINGBOX_AUTO_UPDATE=0，跳过联网检查并复用当前版本\e[0m"
    return 0
  fi

  latest_json=$(fetch_text "https://api.github.com/repos/SagerNet/sing-box/releases/latest")
  latest_version=$(echo "$latest_json" | grep -m1 '"tag_name"' | sed -E 's/.*"v?([^"]+)".*/\1/')

  if [ -z "$latest_version" ]; then
    if [ -n "$current_version" ]; then
      echo -e "\e[1;33m[sing-box] 无法解析 GitHub 最新版本，复用当前版本: v${current_version}\e[0m"
      return 0
    fi
    echo -e "\e[1;31m无法解析 sing-box 最新版本号，且本地没有可用 sing-box\e[0m"
    exit 1
  fi

  echo -e "\e[1;32m[sing-box] GitHub latest release: v${latest_version}\e[0m"

  if [ "$current_version" = "$latest_version" ]; then
    echo -e "\e[1;32m[sing-box] 当前已是最新版本，跳过下载\e[0m"
    echo "$current_version" > "$SINGBOX_VERSION_FILE"
    return 0
  fi

  if [ -n "$current_version" ]; then
    echo -e "\e[1;33m[sing-box] 发现新版本：v${current_version} -> v${latest_version}，开始更新\e[0m"
  else
    echo -e "\e[1;33m[sing-box] 开始首次安装 v${latest_version}\e[0m"
  fi

  install_singbox_version "$latest_version"
  cleanup_old_random_singbox_bins
}

ensure_singbox

# ================== 生成证书（HY2）==================
if ! command -v openssl >/dev/null 2>&1; then
  cat > "${FILE_PATH}/private.key" <<'EOF_KEY'
-----BEGIN EC PARAMETERS-----
BgqghkjOPQQBw==
-----END EC PARAMETERS-----
-----BEGIN EC PRIVATE KEY-----
MHcCAQEEIM4792SEtPqIt1ywqTd/0bYidBqpYV/+siNnfBYsdUYsAoGCCqGSM49
AwEHoUQDQgAE1kHafPj07rJG+HboH2ekAI4r+e6TL38GWASAnngZreoQDF16ARa
/TsyLyFoPkhTxSbehH/OBEjHtSZGaDhMqQ==
-----END EC PRIVATE KEY-----
EOF_KEY

  cat > "${FILE_PATH}/cert.pem" <<'EOF_CERT'
-----BEGIN CERTIFICATE-----
MIIBezCCASCgAwIBAgIUfDCP0kxSK7zlw4GQXq7mkZKFCk8wCgYIKoZIzj0EAwIw
HjEcMBoGA1UEAwwTaXJvaGEuY2xvdWR5dW4ucXp6LmlvMB4XDTI1MDEwMTAxMDEw
MFoXDTM1MDEwMTAxMDEwMFowHjEcMBoGA1UEAwwTaXJvaGEuY2xvdWR5dW4ucXp6
LmlvMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE1kHafPj07rJG+HboH2ekAI4r
+e6TL38GWASAnngZreoQDF16ARa/TsyLyFoPkhTxSbehH/OBEjHtSZGaDhMqKNTMFEw
HQYDVR0OBBYEFNXVwUgPtQhITs8tMFEF8ZuCucw3MB8GA1UdIwQYMBaAFNXVwUgP
tQhITs8tMFEF8ZuCucw3MA8GA1UdEwEB/wQFMAMBAf8wCgYIKoZIzj0EAwIDSAAw
RQIhAMW9QFqG4Z8RvhN8l6YQKu0eIF46w7ryNExS6r4UiZ+JAiBy7PpsP1aURJEU
eUHkOFzmF8WjZSAZSkErCKPNzhS7Pg==
-----END CERTIFICATE-----
EOF_CERT
else
  openssl ecparam -genkey -name prime256v1 -out "${FILE_PATH}/private.key" 2>/dev/null
  openssl req -new -x509 -days 3650 \
    -key "${FILE_PATH}/private.key" \
    -out "${FILE_PATH}/cert.pem" \
    -subj "/CN=${HY2_SNI}" 2>/dev/null
fi

chmod 600 "${FILE_PATH}/private.key"

# ================== 启动/刷新 TCP/HTTP 伪装站 ==================
start_http_masquerade_server

# ================== 生成 sing-box config.json ==================
INBOUNDS=""

if [ "$HY2_PORT" != "" ] && [ "$HY2_PORT" != "0" ]; then
  INBOUNDS="${INBOUNDS}
    {
      \"type\": \"hysteria2\",
      \"tag\": \"hy2-in\",
      \"listen\": \"::\",
      \"listen_port\": ${HY2_PORT},
      \"users\": [
        {
          \"password\": \"${UUID}\"
        }
      ],
      \"masquerade\": \"http://127.0.0.1:${HTTP_LISTEN_PORT}\",
      \"tls\": {
        \"enabled\": true,
        \"server_name\": \"${HY2_SNI}\",
        \"alpn\": [\"h3\"],
        \"certificate_path\": \"${FILE_PATH}/cert.pem\",
        \"key_path\": \"${FILE_PATH}/private.key\"
      }
    }"
fi

cat > "${FILE_PATH}/config.json" <<EOF_CONFIG
{
  "log": {
    "disabled": true
  },
  "inbounds": [
${INBOUNDS}
  ],
  "outbounds": [
    {
      "type": "direct"
    }
  ]
}
EOF_CONFIG

# ================== 启动 sing-box ==================
"$SINGBOX_BIN" run -c "${FILE_PATH}/config.json" &
SINGBOX_PID=$!
echo "[SING-BOX] 启动完成 PID=$SINGBOX_PID"

# ================== 获取 IP & ISP ==================
refresh_meta() {
  IP=$(fetch_quiet "https://ipv4.ip.sb" || fetch_quiet "https://api.ipify.org" || echo "IP_ERROR")
  ISP=$(fetch_quiet "https://speed.cloudflare.com/meta" | awk -F'"' '{print $26"-"$18}' || echo "0.0")
}

print_connection_info() {
  refresh_meta

  echo
  echo -e "\e[1;36m================== 连接信息 ==================\e[0m"
  echo -e "\e[1;32m服务器 IP:\e[0m ${IP}"
  echo -e "\e[1;32mISP:\e[0m ${ISP}"

  if [ "$HY2_PORT" != "" ] && [ "$HY2_PORT" != "0" ]; then
    echo
    echo -e "\e[1;35m[Hysteria2 / UDP]\e[0m"
    echo -e "端口: ${HY2_PORT}"
    echo -e "连接密码: ${UUID}"
    echo -e "TLS SNI: ${HY2_SNI}"
    echo -e "允许不安全证书: true"
    echo -e "ALPN: h3"
    echo -e "伪装类型: proxy"
    echo -e "伪装目标: http://127.0.0.1:${HTTP_LISTEN_PORT}"
    echo
    echo -e "\e[1;35m[HTTP 伪装站 / TCP]\e[0m"
    echo -e "后端模式: ${HTTP_SERVER_MODE}"
    echo -e "端口: ${HTTP_LISTEN_PORT}"
    echo -e "访问地址: http://${IP}:${HTTP_LISTEN_PORT}/"
    echo -e "视频目录: ${FILE_PATH}"
    echo -e "页面目录: ${NGINX_WEB_ROOT}"
    if [ "$ENABLE_MAGNET_DOWNLOADER" = "1" ]; then
      echo -e "下载功能: enabled"
      echo -e "下载目录: ${DOWNLOAD_DIR}"
      echo -e "并发限制: ${DOWNLOAD_MAX_ACTIVE}"
      echo -e "排队限制: ${DOWNLOAD_MAX_QUEUE}"
      if [ -n "$DOWNLOAD_KEY" ]; then
        echo -e "下载密钥: 已启用"
      else
        echo -e "下载密钥: 未启用（DOWNLOAD_KEY_MODE=none，公网不建议）"
      fi
    fi
  fi

  echo -e "\e[1;36m==============================================\e[0m"
  echo
}

print_connection_info

cleanup() {
  kill "$SINGBOX_PID" 2>/dev/null || true
  if [ "$HTTP_SERVER_MODE" = "node" ]; then
    stop_pid_file "$NODE_PID_FILE"
  elif [ "$HTTP_SERVER_MODE" = "python" ]; then
    stop_pid_file "$PYTHON_PID_FILE"
  fi
}
trap cleanup EXIT INT TERM

# ================== 启动定时重启（前台阻塞） ==================
schedule_restart() {
  echo "[定时重启:Sing-box] 已启动（北京时间 04:00）"
  LAST_RESTART_DAY=-1

  while true; do
    now_ts=$(date +%s)
    beijing_ts=$((now_ts + 28800))
    H=$(( (beijing_ts / 3600) % 24 ))
    M=$(( (beijing_ts / 60) % 60 ))
    D=$(( beijing_ts / 86400 ))

    # ---- 时间匹配 → 重启 sing-box，并刷新视频页面 ----
    if [ "$H" -eq 4 ] && [ "$M" -eq 0 ] && [ "$D" -ne "$LAST_RESTART_DAY" ]; then
      echo "[定时重启:Sing-box] 到达 04:00 → 重启 sing-box 并刷新 HTTP 视频页"
      LAST_RESTART_DAY=$D

      reload_http_masquerade_server

      kill "$SINGBOX_PID" 2>/dev/null || true
      sleep 3

      "$SINGBOX_BIN" run -c "${FILE_PATH}/config.json" &
      SINGBOX_PID=$!

      echo "[Sing-box重启完成] 新 PID: $SINGBOX_PID"
      print_connection_info
    fi

    sleep 1
  done
}

# ★★★ 关键：保持脚本前台运行，不能退出
schedule_restart
