#!/usr/bin/env bash
# =============================================================================
# hy2_fakeweb_diag_slim.sh
# 精简诊断版：Hysteria2 + 中文影视网页 + WebTorrent 磁力下载 + trackerlist
#
# 保留功能：
#   - sing-box/HY2 UDP 服务，HTTP 伪装反代到本机 Node 服务
#   - 中文影片网页、视频在线播放、Range 请求
#   - 磁力下载、任务进度、任务移除
#   - tracker 列表默认来自 https://cf.trackerslist.com/all.txt
#   - 影片删除功能，复用同一个访问密钥验证
#   - 磁盘空间显示、本周匿名访客统计
#   - 详细阶段日志、错误行号、失败命令、磁盘诊断、Node 日志尾部
#
# 推荐环境：KataBump / Pterodactyl 类非 root Node 容器。
# 启动方式：bash start.sh，或者 node index.js 前台拉起。
# =============================================================================

set -Eeuo pipefail

# -------------------------- 基础路径与日志 --------------------------
cd "$(dirname "$0")"
export FILE_PATH="${FILE_PATH:-${PWD}/.npm/video}"
export DATA_PATH="${DATA_PATH:-${PWD}/singbox_data}"
export HTTP_RUNTIME_DIR="${HTTP_RUNTIME_DIR:-${FILE_PATH}/http_runtime}"
export DOWNLOAD_DIR="${DOWNLOAD_DIR:-${FILE_PATH}/downloads}"
export NODE_SERVER_JS="${NODE_SERVER_JS:-${HTTP_RUNTIME_DIR}/server.mjs}"
export NODE_PID_FILE="${NODE_PID_FILE:-${HTTP_RUNTIME_DIR}/server.pid}"
export STARTUP_LOG="${STARTUP_LOG:-${HTTP_RUNTIME_DIR}/startup.log}"
export NODE_LOG="${NODE_LOG:-${HTTP_RUNTIME_DIR}/node_http.log}"
mkdir -p "$FILE_PATH" "$DATA_PATH" "$HTTP_RUNTIME_DIR" "$DOWNLOAD_DIR"

log() {
  # 避免使用 tee 管道，降低 set -e/pipefail 下的误退出概率。
  local level="$1"; shift
  local line
  line="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*"
  printf '%s\n' "$line"
  printf '%s\n' "$line" >> "$STARTUP_LOG" 2>/dev/null || true
}

section() { log "STEP" "========== $* =========="; }

print_diag() {
  log "DIAG" "pwd=$(pwd)"
  log "DIAG" "user=$(id -u 2>/dev/null || echo '?'):$(id -g 2>/dev/null || echo '?') shell=$SHELL"
  log "DIAG" "FILE_PATH=$FILE_PATH"
  log "DIAG" "HTTP_RUNTIME_DIR=$HTTP_RUNTIME_DIR"
  log "DIAG" "DOWNLOAD_DIR=$DOWNLOAD_DIR"
  log "DIAG" "磁盘空间："
  df -h "$FILE_PATH" 2>&1 || true
  log "DIAG" "inode："
  df -ih "$FILE_PATH" 2>&1 || true
  log "DIAG" "目录占用 Top 20："
  du -sh "$FILE_PATH"/* "$FILE_PATH"/.[!.]* 2>/dev/null | sort -hr | head -n 20 || true
  if [ -f "$NODE_LOG" ]; then
    log "DIAG" "Node HTTP 日志尾部：$NODE_LOG"
    tail -n 80 "$NODE_LOG" 2>/dev/null || true
  fi
}

on_error() {
  local rc="$?"
  local cmd="${BASH_COMMAND:-unknown}"
  local line="${BASH_LINENO[0]:-${LINENO}}"
  log "ERROR" "脚本失败：exit=$rc line=$line cmd=$cmd"
  print_diag
  exit "$rc"
}
trap on_error ERR

if [ "${HY2_DEBUG:-0}" = "1" ]; then
  export PS4='+ [${BASH_SOURCE##*/}:${LINENO}] '
  set -x
fi

# -------------------------- 用户可配参数 --------------------------
export HY2_PORT="${HY2_PORT:-20164}"
export HTTP_LISTEN_PORT="${HTTP_LISTEN_PORT:-$HY2_PORT}"
export HY2_SNI="${HY2_SNI:-iroha.cloudyun.qzz.io}"
export DOWNLOAD_MAX_ACTIVE="${DOWNLOAD_MAX_ACTIVE:-1}"
export DOWNLOAD_MAX_QUEUE="${DOWNLOAD_MAX_QUEUE:-3}"
export DOWNLOAD_MAX_CONNS="${DOWNLOAD_MAX_CONNS:-32}"
export DOWNLOAD_KEY_MODE="${DOWNLOAD_KEY_MODE:-auto}"       # auto | none
export DOWNLOAD_KEY="${DOWNLOAD_KEY:-}"
export TRACKER_LIST_URL="${TRACKER_LIST_URL:-https://cf.trackerslist.com/all.txt}"
export TRACKER_LIST_CACHE_FILE="${TRACKER_LIST_CACHE_FILE:-${FILE_PATH}/trackers_all.txt}"
export SINGBOX_BIN="${SINGBOX_BIN:-${FILE_PATH}/sing-box}"
export SINGBOX_AUTO_UPDATE="${SINGBOX_AUTO_UPDATE:-1}"
export SINGBOX_MIN_FREE_MB="${SINGBOX_MIN_FREE_MB:-120}"

# -------------------------- 工具函数 --------------------------
fetch_text() {
  local url="$1"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 8 --max-time 30 "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- --timeout=30 "$url"
  else
    log "ERROR" "未找到 curl 或 wget"
    return 1
  fi
}

download_file() {
  local url="$1" out="$2"
  log "INFO" "下载：$url -> $out"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --connect-timeout 8 --max-time 120 -o "$out" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$out" --timeout=120 "$url"
  else
    log "ERROR" "未找到 curl 或 wget"
    return 1
  fi
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

free_mb() {
  df -Pm "$FILE_PATH" 2>/dev/null | awk 'NR==2 {print $4}' || echo 0
}

check_free_space() {
  local free
  free="$(free_mb)"
  log "INFO" "当前可用空间：${free} MiB"
  if [ -n "$free" ] && [ "$free" -lt "$SINGBOX_MIN_FREE_MB" ]; then
    log "ERROR" "空间不足：安装/更新 sing-box 至少建议 ${SINGBOX_MIN_FREE_MB} MiB"
    print_diag
    exit 1
  fi
}

# -------------------------- 密钥与 HY2 密码 --------------------------
setup_keys() {
  section "初始化密码和访问密钥"

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

  local key_file="$FILE_PATH/download_key.txt"
  if [ "$DOWNLOAD_KEY_MODE" = "none" ]; then
    export DOWNLOAD_KEY=""
    log "WARN" "访问密钥已关闭：公网不建议"
  elif [ -n "$DOWNLOAD_KEY" ]; then
    log "INFO" "访问密钥来自环境变量 DOWNLOAD_KEY"
  elif [ -f "$key_file" ]; then
    DOWNLOAD_KEY="$(cat "$key_file")"
    export DOWNLOAD_KEY
    log "INFO" "[访问密钥] 复用：$key_file"
  else
    if have_cmd openssl; then
      DOWNLOAD_KEY="$(openssl rand -hex 16)"
    else
      local u
      u="$(cat /proc/sys/kernel/random/uuid)"
      DOWNLOAD_KEY="${u//-/}"
    fi
    export DOWNLOAD_KEY
    printf '%s\n' "$DOWNLOAD_KEY" > "$key_file"
    chmod 600 "$key_file" || true
    log "INFO" "[访问密钥] 已生成：$DOWNLOAD_KEY"
    log "INFO" "[访问密钥] 文件：$key_file"
  fi
}

# -------------------------- sing-box 安装/复用 --------------------------
singbox_version() {
  local bin="$1"
  [ -x "$bin" ] || return 1
  local out
  out="$($bin version 2>/dev/null || true)"
  case "$out" in
    *sing-box*) : ;;
    *) return 1 ;;
  esac
  if [[ "$out" =~ ([0-9]+\.[0-9]+\.[0-9]+[^[:space:]]*) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

install_singbox() {
  section "检查 sing-box"

  local local_ver=""
  if [ -x "$SINGBOX_BIN" ]; then
    local_ver="$(singbox_version "$SINGBOX_BIN" || true)"
  fi

  if [ -n "$local_ver" ]; then
    log "INFO" "检测到本地 sing-box：$SINGBOX_BIN version=$local_ver"
    if [ "$SINGBOX_AUTO_UPDATE" = "0" ]; then
      log "INFO" "SINGBOX_AUTO_UPDATE=0，跳过联网检查"
      return 0
    fi
  else
    log "INFO" "未检测到可用固定 sing-box：$SINGBOX_BIN"
  fi

  check_free_space

  local arch sb_arch latest_json latest_ver
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) sb_arch="amd64" ;;
    aarch64|arm64) sb_arch="arm64" ;;
    armv7l|armv7) sb_arch="armv7" ;;
    armv6l|armv6) sb_arch="armv6" ;;
    s390x) sb_arch="s390x" ;;
    *) log "ERROR" "不支持的架构：$arch"; exit 1 ;;
  esac
  log "INFO" "系统架构：$arch -> sing-box linux-$sb_arch"

  log "INFO" "获取 sing-box latest release 元数据"
  latest_json="$(fetch_text 'https://api.github.com/repos/SagerNet/sing-box/releases/latest')"
  if [[ "$latest_json" =~ \"tag_name\"[[:space:]]*:[[:space:]]*\"v?([^\"]+)\" ]]; then
    latest_ver="${BASH_REMATCH[1]}"
  else
    log "ERROR" "无法解析 sing-box 最新版本号"
    exit 1
  fi
  log "INFO" "GitHub latest：v$latest_ver"

  if [ -n "$local_ver" ] && [ "$local_ver" = "$latest_ver" ]; then
    log "INFO" "本地 sing-box 已是最新，跳过下载"
    return 0
  fi

  local tmp tarball url src
  tmp="$FILE_PATH/.singbox_tmp"
  rm -rf "$tmp"
  mkdir -p "$tmp"
  tarball="sing-box-${latest_ver}-linux-${sb_arch}.tar.gz"
  url="https://github.com/SagerNet/sing-box/releases/download/v${latest_ver}/${tarball}"

  download_file "$url" "$tmp/$tarball"
  log "INFO" "解压 sing-box 包"
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

# -------------------------- TLS 证书与 sing-box 配置 --------------------------
setup_cert_and_config() {
  section "生成证书和 sing-box 配置"

  if [ ! -f "$FILE_PATH/private.key" ] || [ ! -f "$FILE_PATH/cert.pem" ]; then
    if have_cmd openssl; then
      log "INFO" "使用 openssl 生成自签证书：CN=$HY2_SNI"
      openssl ecparam -genkey -name prime256v1 -out "$FILE_PATH/private.key" 2>/dev/null
      openssl req -new -x509 -days 3650 -key "$FILE_PATH/private.key" -out "$FILE_PATH/cert.pem" -subj "/CN=${HY2_SNI}" 2>/dev/null
    else
      log "ERROR" "未找到 openssl，无法生成证书。请安装 openssl 或预先放置 cert.pem/private.key"
      exit 1
    fi
  else
    log "INFO" "复用已有 TLS 证书"
  fi
  chmod 600 "$FILE_PATH/private.key" || true

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
        "certificate_path": "${FILE_PATH}/cert.pem",
        "key_path": "${FILE_PATH}/private.key"
      }
    }
  ],
  "outbounds": [{ "type": "direct" }]
}
EOF_JSON
  log "INFO" "配置已写入：$FILE_PATH/config.json"
}

# -------------------------- Node / WebTorrent 后端 --------------------------
ensure_webtorrent() {
  section "检查 Node.js 和 WebTorrent"
  if ! have_cmd node; then
    log "ERROR" "未找到 node，精简版需要 Node.js 后端"
    exit 1
  fi
  log "INFO" "Node.js: $(node -v)"

  if ! have_cmd npm; then
    log "ERROR" "未找到 npm，无法安装 WebTorrent"
    exit 1
  fi
  log "INFO" "npm: $(npm -v)"

  if [ -d "$HTTP_RUNTIME_DIR/node_modules/webtorrent" ]; then
    log "INFO" "WebTorrent 模块已存在"
    return 0
  fi

  log "INFO" "首次安装 WebTorrent 到：$HTTP_RUNTIME_DIR"
  cat > "$HTTP_RUNTIME_DIR/package.json" <<'EOF_PACKAGE'
{
  "private": true,
  "type": "module",
  "dependencies": {
    "webtorrent": "latest"
  }
}
EOF_PACKAGE
  (cd "$HTTP_RUNTIME_DIR" && npm install --omit=dev --no-audit --no-fund --loglevel=error)
  log "INFO" "WebTorrent 安装完成"
}

write_node_server() {
  section "写入 Node HTTP 后端"
  cat > "$NODE_SERVER_JS" <<'EOF_NODE'
import http from 'node:http';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
import { URL } from 'node:url';

const port = Number(process.env.HTTP_LISTEN_PORT || process.env.HY2_PORT || 20164);
const fileRoot = path.resolve(process.env.FILE_PATH || path.join(process.cwd(), '.npm/video'));
const downloadRoot = path.resolve(process.env.DOWNLOAD_DIR || path.join(fileRoot, 'downloads'));
const downloadKey = process.env.DOWNLOAD_KEY || '';
const maxActive = Math.max(1, Number(process.env.DOWNLOAD_MAX_ACTIVE || 1));
const maxQueued = Math.max(0, Number(process.env.DOWNLOAD_MAX_QUEUE || 3));
const maxConns = Math.max(12, Number(process.env.DOWNLOAD_MAX_CONNS || 32));
const trackerListUrl = process.env.TRACKER_LIST_URL || 'https://cf.trackerslist.com/all.txt';
const trackerCacheFile = process.env.TRACKER_LIST_CACHE_FILE || path.join(fileRoot, 'trackers_all.txt');
const visitorFile = path.join(fileRoot, 'weekly_visitors.json');
const videoExts = new Set(['.mp4','.m4v','.webm','.mkv','.mov','.avi','.ts','.m3u8']);
const skipDirs = new Set(['http_runtime','nginx_www','node_modules','.git','.cache','.singbox_tmp']);
const mime = {'.mp4':'video/mp4','.m4v':'video/mp4','.webm':'video/webm','.mkv':'video/x-matroska','.mov':'video/quicktime','.avi':'video/x-msvideo','.ts':'video/mp2t','.m3u8':'application/vnd.apple.mpegurl'};

await fsp.mkdir(downloadRoot, { recursive: true });

function log(...args){ console.log(new Date().toISOString(), ...args); }
function human(n){ const u=['B','KB','MB','GB','TB']; let x=Number(n||0),i=0; while(x>=1024&&i<u.length-1){x/=1024;i++;} return i?`${x.toFixed(2)} ${u[i]}`:`${x} ${u[i]}`; }
function esc(s){ return String(s ?? '').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c])); }
function idFromRel(rel){ return Buffer.from(rel,'utf8').toString('base64url'); }
function relFromId(id){ try{return Buffer.from(String(id||''),'base64url').toString('utf8');}catch{return '';} }
function inside(root,target){ const r=path.resolve(root),t=path.resolve(target); return t===r || t.startsWith(r+path.sep); }
function sendJson(res,code,obj){ const body=JSON.stringify(obj); res.writeHead(code, {'Content-Type':'application/json; charset=utf-8','Content-Length':Buffer.byteLength(body),'Cache-Control':'no-store'}); res.end(body); }
function sendText(res,code,txt){ res.writeHead(code, {'Content-Type':'text/plain; charset=utf-8','Cache-Control':'no-store'}); res.end(txt); }
async function readBody(req,limit=8192){ let body=''; for await(const ch of req){ body+=ch; if(body.length>limit) throw new Error('请求体过大'); } return body; }
function authorized(req){ return !downloadKey || String(req.headers['x-library-key']||'') === downloadKey; }

function weekKey(ts=Date.now()){ const d=new Date(ts+8*3600_000); const day=d.getUTCDay()||7; d.setUTCDate(d.getUTCDate()-day+1); return d.toISOString().slice(0,10); }
let visitors = { weekKey: weekKey(), ids: [] };
let visitorSet = new Set();
try { const old = JSON.parse(await fsp.readFile(visitorFile,'utf8')); if (old?.weekKey===weekKey() && Array.isArray(old.ids)) visitors=old; } catch {}
visitorSet = new Set(visitors.ids);
async function saveVisitors(){ try{ await fsp.writeFile(visitorFile+'.tmp', JSON.stringify(visitors), {mode:0o600}); await fsp.rename(visitorFile+'.tmp', visitorFile); }catch{} }
function recordVisit(req){ const wk=weekKey(); if(visitors.weekKey!==wk){ visitors={weekKey:wk,ids:[]}; visitorSet=new Set(); } const ip=String(req.headers['x-forwarded-for']||req.socket.remoteAddress||'').split(',')[0].trim(); const ua=String(req.headers['user-agent']||''); const id=crypto.createHash('sha256').update(ip+'|'+ua).digest('hex').slice(0,24); if(!visitorSet.has(id)){ visitorSet.add(id); visitors.ids.push(id); saveVisitors(); } }

function parseTrackers(txt){ return [...new Set(String(txt||'').split(/\r?\n/).map(s=>s.trim()).filter(s=>s && !s.startsWith('#')).filter(s=>/^(udp|http|https|ws|wss):\/\//i.test(s)))]; }
async function loadTrackers(){
  try {
    const ac = new AbortController(); const timer=setTimeout(()=>ac.abort(), 8000);
    const r = await fetch(trackerListUrl, { signal: ac.signal, headers: {'User-Agent':'Mozilla/5.0'} }); clearTimeout(timer);
    if(!r.ok) throw new Error('HTTP '+r.status);
    const list=parseTrackers(await r.text()); if(!list.length) throw new Error('tracker 列表为空');
    await fsp.writeFile(trackerCacheFile, list.join('\n')+'\n', {mode:0o600}); log('[Tracker] loaded', list.length, 'from', trackerListUrl); return list;
  } catch(e) {
    try { const cached=parseTrackers(await fsp.readFile(trackerCacheFile,'utf8')); if(cached.length){ log('[Tracker] using cache', cached.length); return cached; } } catch {}
    log('[Tracker] load failed:', e?.message || e); return [];
  }
}

let WebTorrent=null, loadErr='';
try { const mod = await import('webtorrent'); WebTorrent = mod.default || mod.WebTorrent || mod; } catch(e) { loadErr = e?.message || String(e); }
const announceList = await loadTrackers();
const client = WebTorrent ? new WebTorrent({ maxConns, tracker: announceList.length ? { announce: announceList } : true }) : null;
if (!client) log('[WebTorrent] unavailable:', loadErr);

const queued=[], failed=new Map(), addedAt=new Map();
const bt32='abcdefghijklmnopqrstuvwxyz234567';
function b32tohex(v){ let bits='',hex=''; for(const ch of String(v).toLowerCase().replace(/=+$/,'')){ const n=bt32.indexOf(ch); if(n<0)return''; bits+=n.toString(2).padStart(5,'0'); } for(let i=0;i+4<=bits.length;i+=4) hex+=parseInt(bits.slice(i,i+4),2).toString(16); return hex; }
function normId(v){ const s=decodeURIComponent(String(v||'')).trim().toLowerCase(); if(/^[a-f0-9]{40}$/.test(s))return s; if(/^[a-z2-7]{32}$/.test(s)){ const h=b32tohex(s); if(/^[a-f0-9]{40}$/.test(h))return h; } return s; }
function magnetId(m){ const x=/(?:^|[?&])xt=urn:btih:([^&]+)/i.exec(String(m||'')); return x?.[1] ? normId(x[1]) : crypto.createHash('sha1').update(String(m||'')).digest('hex'); }
function liveTorrents(){ return client ? client.torrents.filter(t=>t && !t.destroyed && !t.done) : []; }
function allTorrents(){ return client ? client.torrents.filter(t=>t && !t.destroyed) : []; }
function findTorrent(id){ return allTorrents().find(t=>normId(t.infoHash||'')===id); }
function torrentView(t){ const id=normId(t.infoHash||''); return { id, infoHash:id, name:t.name||`下载任务 ${id.slice(0,8)}`, state:t.done?'done':'downloading', progress:Number.isFinite(t.progress)?Math.round(t.progress*1000)/10:0, downloadedText:human(t.downloaded||0), lengthText:t.length?human(t.length):'获取元数据中', downloadSpeedText:human(t.downloadSpeed||0)+'/s', peers:t.numPeers||0, addedAt:addedAt.get(id)||Date.now(), error:'' }; }
function queuedView(q){ return { id:q.id, infoHash:q.id, name:q.name||`排队任务 ${q.id.slice(0,8)}`, state:'queued', progress:0, downloadedText:'0 B', lengthText:'等待中', downloadSpeedText:'排队中', peers:0, addedAt:q.addedAt, error:'' }; }
function failedView([id,e]){ return { id, infoHash:id, name:`失败任务 ${id.slice(0,8)}`, state:'failed', progress:0, downloadedText:'0 B', lengthText:'—', downloadSpeedText:'—', peers:0, addedAt:e.addedAt, error:e.error }; }
function activeCount(){ return liveTorrents().length; }
function startQueue(){ if(!client)return; while(activeCount()<maxActive && queued.length){ const q=queued.shift(); startMagnet(q.magnet, q.id, q.addedAt); } }
function attach(t,id,at){ const remember=()=>{ const h=normId(t.infoHash||id); addedAt.set(h, addedAt.get(id)||at); if(id!==h) addedAt.delete(id); }; t.once('metadata', remember); t.once('ready', remember); t.once('done', ()=>{ remember(); const h=normId(t.infoHash||id); addedAt.delete(h); try{ client.remove(t, {destroyStore:false}, ()=>{}); }catch{} startQueue(); }); t.once('error', e=>{ const h=normId(t.infoHash||id); failed.set(h,{error:e?.message||String(e),addedAt:Date.now()}); try{ client.remove(t,{destroyStore:false},()=>{}); }catch{} startQueue(); }); }
function startMagnet(magnet,id,at){ const t=client.add(magnet, { path:downloadRoot, announce: announceList }); addedAt.set(normId(t.infoHash||id), at); attach(t,id,at); return t; }

function activeVideoRels(){ const s=new Set(); for(const t of liveTorrents()){ for(const f of t.files||[]){ const full=path.resolve(downloadRoot, f.path||f.name||''); if(inside(fileRoot,full)&&videoExts.has(path.extname(full).toLowerCase())) s.add(path.relative(fileRoot,full).split(path.sep).join('/')); } } return s; }
async function walk(dir=fileRoot,depth=0,blocked=activeVideoRels()){ if(depth>6)return[]; let ents=[]; try{ents=await fsp.readdir(dir,{withFileTypes:true});}catch{return[];} const out=[]; for(const ent of ents){ if(ent.name.startsWith('.')&&ent.name!=='.npm')continue; if(skipDirs.has(ent.name))continue; const full=path.join(dir,ent.name); if(!inside(fileRoot,full))continue; if(ent.isDirectory()) out.push(...await walk(full,depth+1,blocked)); else if(ent.isFile()&&videoExts.has(path.extname(ent.name).toLowerCase())){ const st=await fsp.stat(full); const rel=path.relative(fileRoot,full).split(path.sep).join('/'); if(blocked.has(rel))continue; const ext=path.extname(ent.name).toLowerCase(); const id=idFromRel(rel); out.push({id,name:ent.name,rel,size:st.size,sizeText:human(st.size),mtime:st.mtime.toISOString().slice(0,16).replace('T',' '),type:mime[ext]||'application/octet-stream',url:'/media/'+id,thumbUrl:'/thumb/'+id}); } } return out.sort((a,b)=>a.name.localeCompare(b.name,'zh-CN',{numeric:true})); }
async function dirBytes(dir=fileRoot,depth=0){ if(depth>8)return 0; let ents=[]; try{ents=await fsp.readdir(dir,{withFileTypes:true});}catch{return 0;} let total=0; for(const ent of ents){ if(skipDirs.has(ent.name))continue; const full=path.join(dir,ent.name); if(!inside(fileRoot,full))continue; try{ const st=await fsp.stat(full); total += ent.isDirectory()? await dirBytes(full,depth+1) : st.size; }catch{} } return total; }
async function space(){ let total=0,free=0,avail=0,used=0; try{ const s=await fsp.statfs(fileRoot); const b=Number(s.bsize||0); total=Number(s.blocks||0)*b; free=Number(s.bfree||0)*b; avail=Number(s.bavail||0)*b; used=Math.max(0,total-free); }catch{} const lib=await dirBytes(); return {totalText:total?human(total):'—',availableText:avail?human(avail):'—',usedText:total?human(used):human(lib),libraryText:human(lib),usedPct:total?Math.round(used/total*1000)/10:0}; }
function thumb(name){ const h=crypto.createHash('md5').update(name).digest()[0]*360/255|0; return `<svg xmlns="http://www.w3.org/2000/svg" width="640" height="360"><rect width="640" height="360" fill="hsl(${h} 45% 20%)"/><circle cx="320" cy="180" r="58" fill="#0008"/><path d="M304 142v76l60-38z" fill="#fff"/></svg>`; }

async function status(){ return { ok:true, downloadEnabled:!!client, downloadAuthRequired:!!downloadKey, downloadError:client?'':loadErr, maxActive, maxQueued, trackers:announceList.length, visitors:{weekKey:visitors.weekKey,weeklyVisitors:visitorSet.size}, files:await walk(), space:await space(), torrents:[...liveTorrents().map(torrentView),...queued.map(queuedView),...failed.entries()].map(x=>Array.isArray(x)?failedView(x):x).sort((a,b)=>b.addedAt-a.addedAt) }; }

async function addMagnet(req,res){ if(!client)return sendJson(res,503,{ok:false,error:'下载器不可用：'+loadErr}); if(!authorized(req))return sendJson(res,401,{ok:false,error:'访问密钥错误'}); let d; try{d=JSON.parse(await readBody(req));}catch{return sendJson(res,400,{ok:false,error:'请求格式无效'});} const magnet=String(d.magnet||'').trim(); if(!magnet.startsWith('magnet:?')||!/xt=urn:btih:/i.test(magnet))return sendJson(res,400,{ok:false,error:'请输入有效磁力链接'}); const id=magnetId(magnet); const existing=findTorrent(id); if(existing)return sendJson(res,202,{ok:true,torrent:torrentView(existing)}); if(queued.find(q=>q.id===id))return sendJson(res,202,{ok:true,torrent:queuedView(queued.find(q=>q.id===id))}); failed.delete(id); const at=Date.now(); if(activeCount()<maxActive){ try{return sendJson(res,202,{ok:true,torrent:torrentView(startMagnet(magnet,id,at))});}catch(e){failed.set(id,{error:e?.message||String(e),addedAt:at});return sendJson(res,500,{ok:false,error:e?.message||String(e)});} } if(queued.length>=maxQueued)return sendJson(res,429,{ok:false,error:`队列已满：最多 ${maxQueued} 个等待任务`}); const q={id,magnet,addedAt:at,name:`排队任务 ${id.slice(0,8)}`}; queued.push(q); return sendJson(res,202,{ok:true,torrent:queuedView(q)}); }
async function delTask(req,res,id){ if(!authorized(req))return sendJson(res,401,{ok:false,error:'访问密钥错误'}); const qi=queued.findIndex(q=>q.id===id); if(qi>=0){queued.splice(qi,1);return sendJson(res,200,{ok:true});} if(failed.delete(id))return sendJson(res,200,{ok:true}); const t=findTorrent(id); if(!t)return sendJson(res,404,{ok:false,error:'未找到任务'}); try{ client.remove(t,{destroyStore:false},()=>{startQueue();}); return sendJson(res,200,{ok:true}); }catch(e){return sendJson(res,500,{ok:false,error:e?.message||String(e)});} }
async function delFile(req,res,id){ if(!authorized(req))return sendJson(res,401,{ok:false,error:'访问密钥错误'}); const rel=relFromId(id); const full=path.resolve(fileRoot,rel); if(!rel||rel.includes('\0')||!inside(fileRoot,full)||!videoExts.has(path.extname(full).toLowerCase()))return sendJson(res,403,{ok:false,error:'拒绝删除该文件'}); if(activeVideoRels().has(rel))return sendJson(res,409,{ok:false,error:'文件仍在下载中'}); try{ const st=await fsp.stat(full); if(!st.isFile())throw new Error('不是文件'); await fsp.unlink(full); return sendJson(res,200,{ok:true}); }catch(e){return sendJson(res,500,{ok:false,error:e?.message||String(e)});} }

function page(){ return `<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>月光放映室</title><style>:root{color-scheme:dark;--b:#111318;--p:#181b22;--p2:#20252f;--l:#303744;--t:#f3f5f8;--m:#aab2bd;--a:#d8aa4a;--r:#ff8f8f}*{box-sizing:border-box}body{margin:0;background:var(--b);color:var(--t);font:15px/1.6 system-ui,"Microsoft YaHei",sans-serif}.w{width:min(1160px,calc(100% - 28px));margin:auto;padding:24px 0}header{display:flex;justify-content:space-between;gap:12px;align-items:center;margin-bottom:16px}h1{font-size:24px;margin:0}.s{color:var(--m);font-size:13px}.box{background:var(--p);border:1px solid var(--l);border-radius:10px;padding:14px;margin-bottom:14px}.form{display:grid;grid-template-columns:1fr auto;gap:10px}.in,.btn{height:40px;border-radius:7px;font:inherit}.in{border:1px solid var(--l);background:#0f1218;color:var(--t);padding:0 12px}.btn{border:0;background:var(--a);color:#18120a;font-weight:700;padding:0 14px;cursor:pointer}.btn2{border:1px solid var(--l);background:var(--p2);color:var(--t);height:32px;border-radius:6px;cursor:pointer}.stats{display:grid;grid-template-columns:repeat(5,1fr);gap:10px;margin-top:12px}.st{background:var(--p2);border:1px solid var(--l);border-radius:8px;padding:9px}.st span{display:block;color:var(--m);font-size:12px}.bar{height:7px;background:#333b49;border-radius:9px;overflow:hidden;margin-top:8px}.fill{height:100%;background:var(--a);width:0}.lay{display:grid;grid-template-columns:1fr 340px;gap:14px}.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(220px,1fr));gap:12px}.card,.task,.empty{background:var(--p);border:1px solid var(--l);border-radius:10px}.card{overflow:hidden}.task,.empty{padding:12px;margin-bottom:10px;color:var(--m)}video{width:100%;aspect-ratio:16/9;background:#05070b;display:block}.meta{padding:10px}.title{font-weight:700;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.row{display:flex;gap:8px;align-items:center;justify-content:space-between}.msg{min-height:20px;color:var(--m);font-size:13px;margin-top:8px}.bad{color:var(--r)}@media(max-width:850px){.lay,.form,.stats{grid-template-columns:1fr}header{align-items:flex-start;flex-direction:column}}</style></head><body><main class="w"><header><h1>月光放映室</h1><div class="s">本周访客 <b id="vis">—</b></div></header><section class="box"><div class="form"><input id="mag" class="in" placeholder="粘贴 magnet 磁力链接"><button id="add" class="btn">开始下载</button></div><div style="margin-top:10px"><input id="key" class="in" placeholder="访问密钥：下载、移除任务、删除影片时需要" style="width:100%"></div><div class="stats"><div class="st"><span>已用空间</span><b id="used">—</b><div class="bar"><div class="fill" id="sp"></div></div></div><div class="st"><span>可用空间</span><b id="free">—</b></div><div class="st"><span>片库占用</span><b id="lib">—</b></div><div class="st"><span>任务限制</span><b id="lim">—</b></div><div class="st"><span>Tracker</span><b id="trk">—</b></div></div><div id="msg" class="msg"></div></section><section class="lay"><section><h2>影片</h2><div id="grid" class="grid"></div></section><aside><h2>任务</h2><div id="tasks"></div></aside></section></main><script>const $=s=>document.querySelector(s);const esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));function msg(t,b=false){$('#msg').textContent=t||'';$('#msg').className='msg '+(b?'bad':'')}function headers(){const h={};const k=$('#key').value.trim();if(k)h['X-Library-Key']=k;return h}function fhtml(f){return '<article class="card"><video preload="metadata" poster="'+esc(f.thumbUrl)+'" controls><source src="'+esc(f.url)+'" type="'+esc(f.type)+'"></video><div class="meta"><div class="title">'+esc(f.name)+'</div><div class="s">'+esc(f.sizeText)+' · '+esc(f.mtime)+'</div><div class="row"><button class="btn2" data-play="'+esc(f.id)+'">播放</button><button class="btn2" data-del-file="'+esc(f.id)+'">删除</button></div></div></article>'}function thtml(t){return '<div class="task"><div class="row"><b>'+esc(t.name)+'</b><button class="btn2" data-del-task="'+esc(t.id)+'">移除</button></div><div>'+esc(t.state)+' · '+esc(t.downloadedText)+' / '+esc(t.lengthText)+' · '+esc(t.downloadSpeedText)+' · '+esc(t.peers)+' 连接</div>'+(t.error?'<div class="bad">'+esc(t.error)+'</div>':'')+'<div class="bar"><div class="fill" style="width:'+Math.max(0,Math.min(100,t.progress))+'%"></div></div></div>'}async function refresh(){const d=await fetch('/api/status',{cache:'no-store'}).then(r=>r.json());$('#used').textContent=d.space.usedText+' / '+d.space.totalText;$('#free').textContent=d.space.availableText;$('#lib').textContent=d.space.libraryText;$('#lim').textContent=d.maxActive+' 下载 / '+d.maxQueued+' 排队';$('#trk').textContent=d.trackers;$('#vis').textContent=d.visitors.weeklyVisitors;$('#sp').style.width=Math.max(0,Math.min(100,d.space.usedPct||0))+'%';$('#grid').innerHTML=d.files.length?d.files.map(fhtml).join(''):'<div class="empty">暂无影片。</div>';$('#tasks').innerHTML=d.torrents.length?d.torrents.map(thtml).join(''):'<div class="empty">暂无任务。</div>';if(!d.downloadEnabled)msg('下载器不可用：'+d.downloadError,true)}$('#add').onclick=async()=>{const magnet=$('#mag').value.trim();if(!magnet)return msg('请粘贴磁力链接',true);msg('正在创建任务...');const r=await fetch('/api/downloads',{method:'POST',headers:{'Content-Type':'application/json',...headers()},body:JSON.stringify({magnet})});const d=await r.json().catch(()=>({ok:false,error:'请求失败'}));if(!d.ok)return msg(d.error||'创建失败',true);$('#mag').value='';msg('任务已创建');refresh()};document.body.onclick=async e=>{const fd=e.target.dataset.delFile,td=e.target.dataset.delTask,pl=e.target.dataset.play;if(fd){if(!confirm('确认删除这个影片文件？'))return;const d=await fetch('/api/files/'+encodeURIComponent(fd),{method:'DELETE',headers:headers()}).then(r=>r.json());if(!d.ok)msg(d.error,true);refresh()}if(td){const d=await fetch('/api/downloads/'+encodeURIComponent(td),{method:'DELETE',headers:headers()}).then(r=>r.json());if(!d.ok)msg(d.error,true);refresh()}if(pl){const v=e.target.closest('.card')?.querySelector('video');v&&v.play().catch(()=>msg('浏览器无法播放该格式',true))}};refresh();setInterval(refresh,5000)</script></body></html>`; }
function serveThumb(req,res,id){ const rel=relFromId(id), full=path.resolve(fileRoot,rel); if(!inside(fileRoot,full)||!videoExts.has(path.extname(full).toLowerCase()))return sendText(res,403,'Forbidden'); fs.stat(full,(e,st)=>{ if(e||!st.isFile())return sendText(res,404,'Not Found'); const body=thumb(path.basename(full)); res.writeHead(200,{'Content-Type':'image/svg+xml; charset=utf-8','Content-Length':Buffer.byteLength(body),'Cache-Control':'public,max-age=3600'}); if(req.method==='HEAD')return res.end(); res.end(body); }); }
function serveMedia(req,res,id){ const rel=relFromId(id), full=path.resolve(fileRoot,rel); if(!inside(fileRoot,full))return sendText(res,403,'Forbidden'); fs.stat(full,(e,st)=>{ if(e||!st.isFile())return sendText(res,404,'Not Found'); const type=mime[path.extname(full).toLowerCase()]||'application/octet-stream', total=st.size, range=req.headers.range, head=req.method==='HEAD'; const common={'Content-Type':type,'Accept-Ranges':'bytes','X-Content-Type-Options':'nosniff'}; if(range){ const m=/^bytes=(\d*)-(\d*)$/.exec(range); if(!m){res.writeHead(416,{...common,'Content-Range':`bytes */${total}`});return res.end()} let start,end; if(m[1]===''){const suf=Number(m[2]);start=Math.max(total-suf,0);end=total-1}else{start=Number(m[1]);end=m[2]===''?total-1:Number(m[2])} if(!Number.isFinite(start)||!Number.isFinite(end)||start>end||start>=total){res.writeHead(416,{...common,'Content-Range':`bytes */${total}`});return res.end()} end=Math.min(end,total-1); res.writeHead(206,{...common,'Content-Range':`bytes ${start}-${end}/${total}`,'Content-Length':end-start+1}); if(head)return res.end(); return fs.createReadStream(full,{start,end}).pipe(res); } res.writeHead(200,{...common,'Content-Length':total}); if(head)return res.end(); fs.createReadStream(full).pipe(res); }); }

const server=http.createServer(async(req,res)=>{ let p='/'; try{p=new URL(req.url,'http://127.0.0.1').pathname}catch{return sendText(res,400,'Bad Request')} try{ if(req.method==='GET'&&(p==='/'||p==='/index.html')){recordVisit(req);const html=page();res.writeHead(200,{'Content-Type':'text/html; charset=utf-8','Content-Length':Buffer.byteLength(html),'Cache-Control':'no-cache'});return res.end(html)} if(req.method==='GET'&&p==='/api/status')return sendJson(res,200,await status()); if(req.method==='POST'&&p==='/api/downloads')return addMagnet(req,res); if(req.method==='DELETE'&&p.startsWith('/api/downloads/'))return delTask(req,res,decodeURIComponent(p.slice('/api/downloads/'.length))); if(req.method==='DELETE'&&p.startsWith('/api/files/'))return delFile(req,res,decodeURIComponent(p.slice('/api/files/'.length))); if((req.method==='GET'||req.method==='HEAD')&&p.startsWith('/thumb/'))return serveThumb(req,res,decodeURIComponent(p.slice('/thumb/'.length))); if((req.method==='GET'||req.method==='HEAD')&&p.startsWith('/media/'))return serveMedia(req,res,decodeURIComponent(p.slice('/media/'.length))); return sendText(res,404,'Not Found'); }catch(e){ console.error(e); return sendJson(res,500,{ok:false,error:e?.message||String(e)}); }});
server.on('error',e=>{ console.error('[HTTP server error]',e); process.exit(1); });
server.listen(port,'::',()=>log('[HTTP] listening on',port,'root=',fileRoot,'download=',downloadRoot,'auth=',!!downloadKey));
EOF_NODE
  log "INFO" "Node 服务端已写入：$NODE_SERVER_JS"
  node --check "$NODE_SERVER_JS" >/dev/null
  log "INFO" "Node 服务端语法检查通过"
}

start_node_server() {
  section "启动 Node HTTP 后端"
  if [ -f "$NODE_PID_FILE" ]; then
    local old
    old="$(cat "$NODE_PID_FILE" 2>/dev/null || true)"
    if [ -n "$old" ]; then kill "$old" 2>/dev/null || true; fi
    rm -f "$NODE_PID_FILE"
  fi
  : > "$NODE_LOG"
  node "$NODE_SERVER_JS" > "$NODE_LOG" 2>&1 &
  HTTP_PID=$!
  export HTTP_PID
  printf '%s\n' "$HTTP_PID" > "$NODE_PID_FILE"
  sleep 2
  if ! kill -0 "$HTTP_PID" 2>/dev/null; then
    log "ERROR" "Node HTTP 后端启动失败"
    tail -n 120 "$NODE_LOG" 2>/dev/null || true
    exit 1
  fi
  log "INFO" "Node HTTP 后端已启动：pid=$HTTP_PID port=$HTTP_LISTEN_PORT log=$NODE_LOG"
  tail -n 20 "$NODE_LOG" 2>/dev/null || true
}

# -------------------------- sing-box 启动与定时重启 --------------------------
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
  local ip="IP_UNKNOWN"
  ip="$(fetch_text 'https://ipv4.ip.sb' 2>/dev/null || fetch_text 'https://api.ipify.org' 2>/dev/null || echo IP_UNKNOWN)"
  printf '\n================== 连接信息 ==================\n'
  printf '服务器 IP: %s\n' "$ip"
  printf 'HY2 端口: %s/udp\n' "$HY2_PORT"
  printf 'HY2 密码: %s\n' "$UUID"
  printf 'TLS SNI: %s\n' "$HY2_SNI"
  printf '允许不安全证书: true\n'
  printf 'ALPN: h3\n'
  printf 'HTTP 站点: http://%s:%s/\n' "$ip" "$HTTP_LISTEN_PORT"
  printf '访问密钥: %s\n' "${DOWNLOAD_KEY:-未启用}"
  printf 'Tracker 列表: %s\n' "$TRACKER_LIST_URL"
  printf '==============================================\n\n'
}

cleanup_on_exit() {
  local rc="$?"
  log "INFO" "收到退出信号或脚本退出：rc=$rc"
  if [ -n "${SINGBOX_PID:-}" ]; then kill "$SINGBOX_PID" 2>/dev/null || true; fi
  if [ -n "${HTTP_PID:-}" ]; then kill "$HTTP_PID" 2>/dev/null || true; fi
}
trap cleanup_on_exit EXIT INT TERM

schedule_restart_loop() {
  section "进入前台守护循环"
  log "INFO" "每日北京时间 04:00 重启 sing-box；HTTP 后端持续运行"
  local last_day=-1
  while true; do
    if [ -n "${HTTP_PID:-}" ] && ! kill -0 "$HTTP_PID" 2>/dev/null; then
      log "ERROR" "Node HTTP 后端已退出，打印日志后退出主脚本"
      tail -n 120 "$NODE_LOG" 2>/dev/null || true
      exit 1
    fi
    if [ -n "${SINGBOX_PID:-}" ] && ! kill -0 "$SINGBOX_PID" 2>/dev/null; then
      log "ERROR" "sing-box 已退出，主脚本退出以便面板重启"
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
  section "启动脚本"
  log "INFO" "版本：diag-slim-2026-05-04"
  log "INFO" "HY2_PORT=$HY2_PORT HTTP_LISTEN_PORT=$HTTP_LISTEN_PORT HY2_SNI=$HY2_SNI"
  log "INFO" "日志文件：$STARTUP_LOG"
  setup_keys
  install_singbox
  setup_cert_and_config
  ensure_webtorrent
  write_node_server
  start_node_server
  start_singbox
  print_info
  schedule_restart_loop
}

main "$@"
