#!/usr/bin/env node
const fs = require('fs');
const path = require('path');
const { spawn, spawnSync } = require('child_process');

const root = __dirname;
const fileRoot = process.env.FILE_PATH || path.join(root, '.npm', 'video');
const runtimeDir = process.env.HTTP_RUNTIME_DIR || path.join(fileRoot, 'http_runtime');
const downloadDir = process.env.DOWNLOAD_DIR || path.join(fileRoot, 'downloads');
const serverSource = path.join(root, 'server.mjs');
const runtimeServer = path.join(runtimeDir, 'server.mjs');
const certIp = process.env.TLS_CERT_IP || process.env.HY2_SNI || '51.75.118.151';
const certPath = process.env.TLS_CERT_PATH || path.join(fileRoot, 'cert.pem');
const keyPath = process.env.TLS_KEY_PATH || path.join(fileRoot, 'private.key');

const children = new Set();
let shuttingDown = false;

function log(message) {
  console.log(`[index.js] ${message}`);
}

function mkdirp(dir) {
  fs.mkdirSync(dir, { recursive: true });
}

function run(command, args, options = {}) {
  const result = spawnSync(command, args, { stdio: 'inherit', shell: false, ...options });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    throw new Error(`${command} ${args.join(' ')} exited with ${result.status}`);
  }
}

function ensureCertificate() {
  if (fs.existsSync(certPath) && fs.existsSync(keyPath)) {
    log(`reuse TLS certificate: ${certPath}`);
    return;
  }

  // Web 和 sing-box 共用这张证书。这里用最朴素的 RSA-2048 自签证书，
  // 并把服务器 IP 写进 SAN，浏览器和 HY2 客户端看到的证书身份保持一致。
  log(`generate self-signed TLS certificate for IP ${certIp}`);
  const openssl = process.platform === 'win32' ? 'openssl.exe' : 'openssl';
  run(openssl, [
    'req',
    '-x509',
    '-newkey',
    'rsa:2048',
    '-sha256',
    '-nodes',
    '-days',
    '3650',
    '-keyout',
    keyPath,
    '-out',
    certPath,
    '-subj',
    `/CN=${certIp}`,
    '-addext',
    `subjectAltName=IP:${certIp}`,
  ]);
}

function ensureWebTorrentRuntime() {
  if (fs.existsSync(path.join(runtimeDir, 'node_modules', 'webtorrent'))) {
    log('reuse WebTorrent runtime');
    return;
  }

  // 面板里不用再填 ADDITIONAL NODE PACKAGES；入口脚本会把后端依赖装到持久目录。
  log('install WebTorrent runtime package');
  fs.writeFileSync(
    path.join(runtimeDir, 'package.json'),
    JSON.stringify({ type: 'module', private: true, dependencies: { webtorrent: 'latest' } }, null, 2),
  );
  run(process.platform === 'win32' ? 'npm.cmd' : 'npm', ['install', '--omit=dev'], { cwd: runtimeDir });
}

function copyServer() {
  fs.copyFileSync(serverSource, runtimeServer);
}

function spawnChild(label, command, args, env) {
  const child = spawn(command, args, {
    cwd: root,
    stdio: 'inherit',
    env: { ...process.env, ...env },
  });

  children.add(child);
  child.on('exit', (code, signal) => {
    children.delete(child);
    log(`${label} exited: code=${code}, signal=${signal}`);
    if (!shuttingDown) shutdown(code ?? 1);
  });
  return child;
}

function shutdown(code = 0) {
  if (shuttingDown) return;
  shuttingDown = true;
  for (const child of children) child.kill('SIGTERM');
  setTimeout(() => {
    for (const child of children) child.kill('SIGKILL');
    process.exit(code);
  }, 3000).unref();
}

function main() {
  mkdirp(fileRoot);
  mkdirp(runtimeDir);
  mkdirp(downloadDir);
  ensureCertificate();
  ensureWebTorrentRuntime();
  copyServer();

  const sharedEnv = {
    FILE_PATH: fileRoot,
    HTTP_RUNTIME_DIR: runtimeDir,
    DOWNLOAD_DIR: downloadDir,
    TLS_CERT_IP: certIp,
    HY2_SNI: process.env.HY2_SNI || certIp,
    TLS_CERT_PATH: certPath,
    TLS_KEY_PATH: keyPath,
    FRONTEND_DIST_DIR: process.env.FRONTEND_DIST_DIR || path.join(root, 'dist'),
  };

  // Node 负责 HTTPS Web、React dist、WebTorrent API、/media Range。
  spawnChild('web', process.execPath, [runtimeServer], sharedEnv);

  // Bash 脚本放在根目录，便于在面板文件管理器里直接上传和排查。
  spawnChild('runtime', 'bash', ['hy2_fakeweb.sh'], sharedEnv);
}

process.on('SIGTERM', () => shutdown(0));
process.on('SIGINT', () => shutdown(0));

try {
  main();
} catch (error) {
  console.error('[index.js] startup failed:', error);
  shutdown(1);
}
