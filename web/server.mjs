import https from 'node:https';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
import { URL } from 'node:url';

const port = Number(process.env.HTTP_LISTEN_PORT || process.env.HY2_PORT || 20164);
const fileRoot = path.resolve(process.env.FILE_PATH || path.join(process.cwd(), '.npm/video'));
const downloadRoot = path.resolve(process.env.DOWNLOAD_DIR || path.join(fileRoot, 'downloads'));
const frontendDist = path.resolve(process.env.FRONTEND_DIST_DIR || path.join(process.cwd(), 'dist'));
const certPath = path.resolve(process.env.TLS_CERT_PATH || path.join(fileRoot, 'cert.pem'));
const keyPath = path.resolve(process.env.TLS_KEY_PATH || path.join(fileRoot, 'private.key'));
const downloadKeyFile = path.join(fileRoot, 'download_key.txt');
const downloadKey = loadDownloadKey();
const maxActive = Math.max(1, Number(process.env.DOWNLOAD_MAX_ACTIVE || 1));
const maxQueued = Math.max(0, Number(process.env.DOWNLOAD_MAX_QUEUE || 3));
const maxConns = Math.max(12, Number(process.env.DOWNLOAD_MAX_CONNS || 32));
const trackerListUrl = process.env.TRACKER_LIST_URL || 'https://cf.trackerslist.com/all.txt';
const trackerCacheFile = process.env.TRACKER_LIST_CACHE_FILE || path.join(fileRoot, 'trackers_all.txt');
const visitorFile = path.join(fileRoot, 'weekly_visitors.json');
const videoExts = new Set(['.mp4', '.m4v', '.webm', '.mkv', '.mov', '.avi', '.ts', '.m3u8']);
const skipDirs = new Set(['http_runtime', 'nginx_www', 'node_modules', '.git', '.cache', '.singbox_tmp']);
const mime = {
  '.mp4': 'video/mp4',
  '.m4v': 'video/mp4',
  '.webm': 'video/webm',
  '.mkv': 'video/x-matroska',
  '.mov': 'video/quicktime',
  '.avi': 'video/x-msvideo',
  '.ts': 'video/mp2t',
  '.m3u8': 'application/vnd.apple.mpegurl',
};

function loadDownloadKey() {
  if (process.env.DOWNLOAD_KEY) return process.env.DOWNLOAD_KEY;
  try {
    const key = fs.readFileSync(downloadKeyFile, 'utf8').trim();
    if (key) return key;
  } catch {
    // Generate below when the key file does not exist yet.
  }
  const key = crypto.randomUUID();
  fs.mkdirSync(fileRoot, { recursive: true });
  fs.writeFileSync(downloadKeyFile, `${key}\n`, { mode: 0o600 });
  return key;
}
const staticMime = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml; charset=utf-8',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.webp': 'image/webp',
  '.ico': 'image/x-icon',
  '.txt': 'text/plain; charset=utf-8',
};

await fsp.mkdir(downloadRoot, { recursive: true });

function log(...args) {
  console.log(new Date().toISOString(), ...args);
}

function human(n) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let value = Number(n || 0);
  let index = 0;
  while (value >= 1024 && index < units.length - 1) {
    value /= 1024;
    index += 1;
  }
  return index ? `${value.toFixed(2)} ${units[index]}` : `${value} ${units[index]}`;
}

function idFromRel(rel) {
  return Buffer.from(rel, 'utf8').toString('base64url');
}

function relFromId(id) {
  try {
    return Buffer.from(String(id || ''), 'base64url').toString('utf8');
  } catch {
    return '';
  }
}

function inside(root, target) {
  const resolvedRoot = path.resolve(root);
  const resolvedTarget = path.resolve(target);
  return resolvedTarget === resolvedRoot || resolvedTarget.startsWith(resolvedRoot + path.sep);
}

function sendJson(res, code, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(code, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(body),
    'Cache-Control': 'no-store',
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
    if (body.length > limit) throw new Error('请求体过大');
  }
  return body;
}

function authorized(req) {
  return !downloadKey || String(req.headers['x-library-key'] || '') === downloadKey;
}

function weekKey(ts = Date.now()) {
  const date = new Date(ts + 8 * 3600_000);
  const day = date.getUTCDay() || 7;
  date.setUTCDate(date.getUTCDate() - day + 1);
  return date.toISOString().slice(0, 10);
}

let visitors = { weekKey: weekKey(), ids: [] };
let visitorSet = new Set();
try {
  const old = JSON.parse(await fsp.readFile(visitorFile, 'utf8'));
  if (old?.weekKey === weekKey() && Array.isArray(old.ids)) visitors = old;
} catch {}
visitorSet = new Set(visitors.ids);

async function saveVisitors() {
  try {
    await fsp.writeFile(`${visitorFile}.tmp`, JSON.stringify(visitors), { mode: 0o600 });
    await fsp.rename(`${visitorFile}.tmp`, visitorFile);
  } catch {}
}

function recordVisit(req) {
  const currentWeek = weekKey();
  if (visitors.weekKey !== currentWeek) {
    visitors = { weekKey: currentWeek, ids: [] };
    visitorSet = new Set();
  }
  const ip = String(req.headers['x-forwarded-for'] || req.socket.remoteAddress || '').split(',')[0].trim();
  const ua = String(req.headers['user-agent'] || '');
  const id = crypto.createHash('sha256').update(`${ip}|${ua}`).digest('hex').slice(0, 24);
  if (!visitorSet.has(id)) {
    visitorSet.add(id);
    visitors.ids.push(id);
    saveVisitors();
  }
}

function parseTrackers(text) {
  return [...new Set(String(text || '')
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line && !line.startsWith('#'))
    .filter((line) => /^(udp|http|https|ws|wss):\/\//i.test(line)))];
}

async function loadTrackers() {
  try {
    const ac = new AbortController();
    const timer = setTimeout(() => ac.abort(), 8000);
    const response = await fetch(trackerListUrl, { signal: ac.signal, headers: { 'User-Agent': 'Mozilla/5.0' } });
    clearTimeout(timer);
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const list = parseTrackers(await response.text());
    if (!list.length) throw new Error('tracker 列表为空');
    await fsp.writeFile(trackerCacheFile, `${list.join('\n')}\n`, { mode: 0o600 });
    log('[Tracker] loaded', list.length, 'from', trackerListUrl);
    return list;
  } catch (error) {
    try {
      const cached = parseTrackers(await fsp.readFile(trackerCacheFile, 'utf8'));
      if (cached.length) {
        log('[Tracker] using cache', cached.length);
        return cached;
      }
    } catch {}
    log('[Tracker] load failed:', error?.message || error);
    return [];
  }
}

let WebTorrent = null;
let loadErr = '';
try {
  const mod = await import('webtorrent');
  WebTorrent = mod.default || mod.WebTorrent || mod;
} catch (error) {
  loadErr = error?.message || String(error);
}
const announceList = await loadTrackers();
const client = WebTorrent ? new WebTorrent({ maxConns, tracker: announceList.length ? { announce: announceList } : true }) : null;
if (!client) log('[WebTorrent] unavailable:', loadErr);

const queued = [];
const failed = new Map();
const addedAt = new Map();
const base32Chars = 'abcdefghijklmnopqrstuvwxyz234567';

function base32ToHex(value) {
  let bits = '';
  let hex = '';
  for (const char of String(value).toLowerCase().replace(/=+$/, '')) {
    const n = base32Chars.indexOf(char);
    if (n < 0) return '';
    bits += n.toString(2).padStart(5, '0');
  }
  for (let i = 0; i + 4 <= bits.length; i += 4) hex += parseInt(bits.slice(i, i + 4), 2).toString(16);
  return hex;
}

function normId(value) {
  const text = decodeURIComponent(String(value || '')).trim().toLowerCase();
  if (/^[a-f0-9]{40}$/.test(text)) return text;
  if (/^[a-z2-7]{32}$/.test(text)) {
    const hex = base32ToHex(text);
    if (/^[a-f0-9]{40}$/.test(hex)) return hex;
  }
  return text;
}

function magnetId(magnet) {
  const match = /(?:^|[?&])xt=urn:btih:([^&]+)/i.exec(String(magnet || ''));
  return match?.[1] ? normId(match[1]) : crypto.createHash('sha1').update(String(magnet || '')).digest('hex');
}

function liveTorrents() {
  return client ? client.torrents.filter((torrent) => torrent && !torrent.destroyed && !torrent.done) : [];
}

function allTorrents() {
  return client ? client.torrents.filter((torrent) => torrent && !torrent.destroyed) : [];
}

function findTorrent(id) {
  return allTorrents().find((torrent) => normId(torrent.infoHash || '') === id);
}

function torrentView(torrent) {
  const id = normId(torrent.infoHash || '');
  return {
    id,
    infoHash: id,
    name: torrent.name || `下载任务 ${id.slice(0, 8)}`,
    state: torrent.done ? 'done' : 'downloading',
    progress: Number.isFinite(torrent.progress) ? Math.round(torrent.progress * 1000) / 10 : 0,
    downloadedText: human(torrent.downloaded || 0),
    lengthText: torrent.length ? human(torrent.length) : '获取元数据中',
    downloadSpeedText: `${human(torrent.downloadSpeed || 0)}/s`,
    peers: torrent.numPeers || 0,
    addedAt: addedAt.get(id) || Date.now(),
    error: '',
  };
}

function queuedView(item) {
  return {
    id: item.id,
    infoHash: item.id,
    name: item.name || `排队任务 ${item.id.slice(0, 8)}`,
    state: 'queued',
    progress: 0,
    downloadedText: '0 B',
    lengthText: '等待中',
    downloadSpeedText: '排队中',
    peers: 0,
    addedAt: item.addedAt,
    error: '',
  };
}

function failedView([id, error]) {
  return {
    id,
    infoHash: id,
    name: `失败任务 ${id.slice(0, 8)}`,
    state: 'failed',
    progress: 0,
    downloadedText: '0 B',
    lengthText: '—',
    downloadSpeedText: '—',
    peers: 0,
    addedAt: error.addedAt,
    error: error.error,
  };
}

function activeCount() {
  return liveTorrents().length;
}

function startQueue() {
  if (!client) return;
  while (activeCount() < maxActive && queued.length) {
    const item = queued.shift();
    try {
      startMagnet(item.magnet, item.id, item.addedAt);
    } catch (error) {
      // 队列项已经移出 queued，启动失败时必须保留为 failed，
      // 否则用户看到的排队任务会“凭空消失”。
      failed.set(item.id, { error: error?.message || String(error), addedAt: item.addedAt || Date.now() });
      log('[Queue] failed to start queued task', item.id, error?.message || error);
    }
  }
}

function attachTorrent(torrent, id, at) {
  const remember = () => {
    const hash = normId(torrent.infoHash || id);
    addedAt.set(hash, addedAt.get(id) || at);
    if (id !== hash) addedAt.delete(id);
  };
  torrent.once('metadata', remember);
  torrent.once('ready', remember);
  torrent.once('done', () => {
    remember();
    const hash = normId(torrent.infoHash || id);
    addedAt.delete(hash);
    try {
      client.remove(torrent, { destroyStore: false }, () => {});
    } catch {}
    startQueue();
  });
  torrent.once('error', (error) => {
    const hash = normId(torrent.infoHash || id);
    failed.set(hash, { error: error?.message || String(error), addedAt: Date.now() });
    try {
      client.remove(torrent, { destroyStore: false }, () => {});
    } catch {}
    startQueue();
  });
}

function startMagnet(magnet, id, at) {
  const torrent = client.add(magnet, { path: downloadRoot, announce: announceList });
  addedAt.set(normId(torrent.infoHash || id), at);
  attachTorrent(torrent, id, at);
  return torrent;
}

function activeVideoRels() {
  const blocked = new Set();
  for (const torrent of liveTorrents()) {
    for (const file of torrent.files || []) {
      const full = path.resolve(downloadRoot, file.path || file.name || '');
      if (inside(fileRoot, full) && videoExts.has(path.extname(full).toLowerCase())) {
        blocked.add(path.relative(fileRoot, full).split(path.sep).join('/'));
      }
    }
  }
  return blocked;
}

async function walk(dir = fileRoot, depth = 0, blocked = activeVideoRels()) {
  if (depth > 6) return [];
  let entries = [];
  try {
    entries = await fsp.readdir(dir, { withFileTypes: true });
  } catch {
    return [];
  }
  const out = [];
  for (const entry of entries) {
    if (entry.name.startsWith('.') && entry.name !== '.npm') continue;
    if (skipDirs.has(entry.name)) continue;
    const full = path.join(dir, entry.name);
    if (!inside(fileRoot, full)) continue;
    if (entry.isDirectory()) out.push(...await walk(full, depth + 1, blocked));
    else if (entry.isFile() && videoExts.has(path.extname(entry.name).toLowerCase())) {
      const stat = await fsp.stat(full);
      const rel = path.relative(fileRoot, full).split(path.sep).join('/');
      if (blocked.has(rel)) continue;
      const ext = path.extname(entry.name).toLowerCase();
      const id = idFromRel(rel);
      out.push({
        id,
        name: entry.name,
        rel,
        size: stat.size,
        sizeText: human(stat.size),
        mtime: stat.mtime.toISOString().slice(0, 16).replace('T', ' '),
        type: mime[ext] || 'application/octet-stream',
        url: `/media/${id}`,
        thumbUrl: `/thumb/${id}`,
      });
    }
  }
  return out.sort((a, b) => a.name.localeCompare(b.name, 'zh-CN', { numeric: true }));
}

async function dirBytes(dir = fileRoot, depth = 0) {
  if (depth > 8) return 0;
  let entries = [];
  try {
    entries = await fsp.readdir(dir, { withFileTypes: true });
  } catch {
    return 0;
  }
  let total = 0;
  for (const entry of entries) {
    if (skipDirs.has(entry.name)) continue;
    const full = path.join(dir, entry.name);
    if (!inside(fileRoot, full)) continue;
    try {
      const stat = await fsp.stat(full);
      total += entry.isDirectory() ? await dirBytes(full, depth + 1) : stat.size;
    } catch {}
  }
  return total;
}

async function space() {
  let total = 0;
  let free = 0;
  let avail = 0;
  let used = 0;
  try {
    const stat = await fsp.statfs(fileRoot);
    const block = Number(stat.bsize || 0);
    total = Number(stat.blocks || 0) * block;
    free = Number(stat.bfree || 0) * block;
    avail = Number(stat.bavail || 0) * block;
    used = Math.max(0, total - free);
  } catch {}
  const lib = await dirBytes();
  return {
    totalText: total ? human(total) : '—',
    availableText: avail ? human(avail) : '—',
    usedText: total ? human(used) : human(lib),
    libraryText: human(lib),
    usedPct: total ? Math.round((used / total) * 1000) / 10 : 0,
  };
}

function thumb(name) {
  const hue = crypto.createHash('md5').update(name).digest()[0] * 360 / 255 | 0;
  return `<svg xmlns="http://www.w3.org/2000/svg" width="640" height="360"><rect width="640" height="360" fill="hsl(${hue} 45% 20%)"/><circle cx="320" cy="180" r="58" fill="#0008"/><path d="M304 142v76l60-38z" fill="#fff"/></svg>`;
}

async function status() {
  return {
    ok: true,
    downloadEnabled: !!client,
    downloadAuthRequired: !!downloadKey,
    downloadError: client ? '' : loadErr,
    maxActive,
    maxQueued,
    trackers: announceList.length,
    visitors: { weekKey: visitors.weekKey, weeklyVisitors: visitorSet.size },
    files: await walk(),
    space: await space(),
    torrents: [
      ...liveTorrents().map(torrentView),
      ...queued.map(queuedView),
      ...failed.entries(),
    ].map((item) => (Array.isArray(item) ? failedView(item) : item)).sort((a, b) => b.addedAt - a.addedAt),
  };
}

async function addMagnet(req, res) {
  if (!client) return sendJson(res, 503, { ok: false, error: `下载器不可用：${loadErr}` });
  if (!authorized(req)) return sendJson(res, 401, { ok: false, error: '访问密钥错误' });
  let data;
  try {
    data = JSON.parse(await readBody(req));
  } catch {
    return sendJson(res, 400, { ok: false, error: '请求格式无效' });
  }
  const magnet = String(data.magnet || '').trim();
  if (!magnet.startsWith('magnet:?') || !/xt=urn:btih:/i.test(magnet)) {
    return sendJson(res, 400, { ok: false, error: '请输入有效磁力链接' });
  }
  const id = magnetId(magnet);
  const existing = findTorrent(id);
  if (existing) return sendJson(res, 202, { ok: true, torrent: torrentView(existing) });
  const queuedItem = queued.find((item) => item.id === id);
  if (queuedItem) return sendJson(res, 202, { ok: true, torrent: queuedView(queuedItem) });

  failed.delete(id);
  const at = Date.now();
  if (activeCount() < maxActive) {
    try {
      return sendJson(res, 202, { ok: true, torrent: torrentView(startMagnet(magnet, id, at)) });
    } catch (error) {
      failed.set(id, { error: error?.message || String(error), addedAt: at });
      return sendJson(res, 500, { ok: false, error: error?.message || String(error) });
    }
  }

  if (queued.length >= maxQueued) return sendJson(res, 429, { ok: false, error: `队列已满：最多 ${maxQueued} 个等待任务` });
  const item = { id, magnet, addedAt: at, name: `排队任务 ${id.slice(0, 8)}` };
  queued.push(item);
  return sendJson(res, 202, { ok: true, torrent: queuedView(item) });
}

async function delTask(req, res, id) {
  if (!authorized(req)) return sendJson(res, 401, { ok: false, error: '访问密钥错误' });
  const queueIndex = queued.findIndex((item) => item.id === id);
  if (queueIndex >= 0) {
    queued.splice(queueIndex, 1);
    return sendJson(res, 200, { ok: true });
  }
  if (failed.delete(id)) return sendJson(res, 200, { ok: true });
  const torrent = findTorrent(id);
  if (!torrent) return sendJson(res, 404, { ok: false, error: '未找到任务' });
  try {
    client.remove(torrent, { destroyStore: false }, () => startQueue());
    return sendJson(res, 200, { ok: true });
  } catch (error) {
    return sendJson(res, 500, { ok: false, error: error?.message || String(error) });
  }
}

async function delFile(req, res, id) {
  if (!authorized(req)) return sendJson(res, 401, { ok: false, error: '访问密钥错误' });
  const rel = relFromId(id);
  const full = path.resolve(fileRoot, rel);
  if (!rel || rel.includes('\0') || !inside(fileRoot, full) || !videoExts.has(path.extname(full).toLowerCase())) {
    return sendJson(res, 403, { ok: false, error: '拒绝删除该文件' });
  }
  if (activeVideoRels().has(rel)) return sendJson(res, 409, { ok: false, error: '文件仍在下载中' });
  try {
    const stat = await fsp.stat(full);
    if (!stat.isFile()) throw new Error('不是文件');
    await fsp.unlink(full);
    return sendJson(res, 200, { ok: true });
  } catch (error) {
    return sendJson(res, 500, { ok: false, error: error?.message || String(error) });
  }
}

function serveThumb(req, res, id) {
  const rel = relFromId(id);
  const full = path.resolve(fileRoot, rel);
  if (!inside(fileRoot, full) || !videoExts.has(path.extname(full).toLowerCase())) return sendText(res, 403, 'Forbidden');
  fs.stat(full, (error, stat) => {
    if (error || !stat.isFile()) return sendText(res, 404, 'Not Found');
    const body = thumb(path.basename(full));
    res.writeHead(200, {
      'Content-Type': 'image/svg+xml; charset=utf-8',
      'Content-Length': Buffer.byteLength(body),
      'Cache-Control': 'public,max-age=3600',
    });
    if (req.method === 'HEAD') return res.end();
    res.end(body);
  });
}

function serveMedia(req, res, id) {
  const rel = relFromId(id);
  const full = path.resolve(fileRoot, rel);
  if (!inside(fileRoot, full)) return sendText(res, 403, 'Forbidden');
  fs.stat(full, (error, stat) => {
    if (error || !stat.isFile()) return sendText(res, 404, 'Not Found');
    const type = mime[path.extname(full).toLowerCase()] || 'application/octet-stream';
    const total = stat.size;
    const range = req.headers.range;
    const head = req.method === 'HEAD';
    const common = { 'Content-Type': type, 'Accept-Ranges': 'bytes', 'X-Content-Type-Options': 'nosniff' };

    if (range) {
      const match = /^bytes=(\d*)-(\d*)$/.exec(range);
      if (!match) {
        res.writeHead(416, { ...common, 'Content-Range': `bytes */${total}` });
        return res.end();
      }
      let start;
      let end;
      if (match[1] === '') {
        const suffix = Number(match[2]);
        start = Math.max(total - suffix, 0);
        end = total - 1;
      } else {
        start = Number(match[1]);
        end = match[2] === '' ? total - 1 : Number(match[2]);
      }
      if (!Number.isFinite(start) || !Number.isFinite(end) || start > end || start >= total) {
        res.writeHead(416, { ...common, 'Content-Range': `bytes */${total}` });
        return res.end();
      }
      end = Math.min(end, total - 1);
      res.writeHead(206, { ...common, 'Content-Range': `bytes ${start}-${end}/${total}`, 'Content-Length': end - start + 1 });
      if (head) return res.end();
      return fs.createReadStream(full, { start, end }).pipe(res);
    }

    res.writeHead(200, { ...common, 'Content-Length': total });
    if (head) return res.end();
    fs.createReadStream(full).pipe(res);
  });
}

async function serveDist(req, res, pathname) {
  if (req.method !== 'GET' && req.method !== 'HEAD') return false;
  if (pathname.startsWith('/api/') || pathname.startsWith('/media/') || pathname.startsWith('/thumb/')) return false;

  let rel = pathname === '/' ? 'index.html' : decodeURIComponent(pathname.slice(1));
  if (!rel || rel.includes('\0') || rel.split('/').includes('..')) return false;
  let full = path.resolve(frontendDist, rel);
  if (!inside(frontendDist, full)) return false;

  let stat;
  try {
    stat = await fsp.stat(full);
    if (stat.isDirectory()) {
      full = path.join(full, 'index.html');
      stat = await fsp.stat(full);
    }
  } catch {
    if (path.extname(rel)) return false;
    full = path.join(frontendDist, 'index.html');
    try {
      stat = await fsp.stat(full);
    } catch {
      return false;
    }
  }
  if (!stat.isFile()) return false;
  const ext = path.extname(full).toLowerCase();
  const cache = rel.startsWith('assets/') ? 'public,max-age=31536000,immutable' : 'no-cache';
  res.writeHead(200, {
    'Content-Type': staticMime[ext] || 'application/octet-stream',
    'Content-Length': stat.size,
    'Cache-Control': cache,
    'X-Content-Type-Options': 'nosniff',
  });
  if (req.method === 'HEAD') return res.end(), true;
  fs.createReadStream(full).pipe(res);
  return true;
}

const server = https.createServer({
  cert: fs.readFileSync(certPath),
  key: fs.readFileSync(keyPath),
  // 证书本身不区分 TLS 版本；这里限制 Web HTTPS 握手使用 TLS 1.3。
  // sing-box 的 hysteria2/QUIC 同样复用这张证书。
  minVersion: 'TLSv1.3',
}, async (req, res) => {
  let pathname = '/';
  try {
    pathname = new URL(req.url, 'https://127.0.0.1').pathname;
  } catch {
    return sendText(res, 400, 'Bad Request');
  }

  try {
    if (req.method === 'GET' && pathname === '/api/status') return sendJson(res, 200, await status());
    if (req.method === 'POST' && pathname === '/api/downloads') return addMagnet(req, res);
    if (req.method === 'DELETE' && pathname.startsWith('/api/downloads/')) {
      return delTask(req, res, decodeURIComponent(pathname.slice('/api/downloads/'.length)));
    }
    if (req.method === 'DELETE' && pathname.startsWith('/api/files/')) {
      return delFile(req, res, decodeURIComponent(pathname.slice('/api/files/'.length)));
    }
    if ((req.method === 'GET' || req.method === 'HEAD') && pathname.startsWith('/thumb/')) {
      return serveThumb(req, res, decodeURIComponent(pathname.slice('/thumb/'.length)));
    }
    if ((req.method === 'GET' || req.method === 'HEAD') && pathname.startsWith('/media/')) {
      return serveMedia(req, res, decodeURIComponent(pathname.slice('/media/'.length)));
    }

    if (req.method === 'GET' && (pathname === '/' || pathname === '/index.html')) recordVisit(req);
    if (await serveDist(req, res, pathname)) return;
    return sendText(res, 404, 'Not Found');
  } catch (error) {
    console.error(error);
    return sendJson(res, 500, { ok: false, error: error?.message || String(error) });
  }
});

server.on('error', (error) => {
  console.error('[HTTPS server error]', error);
  process.exit(1);
});

server.listen(port, '::', () => {
  log(
    '[HTTPS] listening on',
    port,
    'frontend=',
    frontendDist,
    'root=',
    fileRoot,
    'download=',
    downloadRoot,
    'auth=',
    !!downloadKey,
    'DOWNLOAD_KEY=',
    downloadKey || '未设置，无需密码',
  );
});
