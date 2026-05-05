#!/usr/bin/env node

import fs from 'fs';
import path from 'path';
import crypto from 'crypto';
import { spawn, spawnSync } from 'child_process';
import { fileURLToPath } from 'url';

// 计算 __dirname 的 ES 模块等价写法
const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const root = __dirname;
const fileRoot = process.env.FILE_PATH || path.join(root, '.npm', 'video');
const runtimeDir = process.env.HTTP_RUNTIME_DIR || path.join(fileRoot, 'http_runtime');
const downloadDir = process.env.DOWNLOAD_DIR || path.join(fileRoot, 'downloads');
const serverSource = path.join(root, 'server.mjs');
const runtimeServer = path.join(runtimeDir, 'server.mjs');
const runtimeScript = path.join(root, 'hy2_fakeweb.sh');
const certIp = process.env.TLS_CERT_IP || process.env.HY2_SNI || '51.75.118.151';
const certPath = process.env.TLS_CERT_PATH || path.join(fileRoot, 'cert.pem');
const keyPath = process.env.TLS_KEY_PATH || path.join(fileRoot, 'private.key');
const downloadKeyPath = path.join(fileRoot, 'download_key.txt');

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

  log('install WebTorrent runtime package');
  fs.writeFileSync(
    path.join(runtimeDir, 'package.json'),
    JSON.stringify({ type: 'module', private: true, dependencies: { webtorrent: 'latest' } }, null, 2),
  );
  run(process.platform === 'win32' ? 'npm.cmd' : 'npm', ['install', '--omit=dev'], { cwd: runtimeDir });
}

function ensureDownloadKey() {
  if (process.env.DOWNLOAD_KEY) {
    log(`use DOWNLOAD_KEY from environment: ${process.env.DOWNLOAD_KEY}`);
    return process.env.DOWNLOAD_KEY;
  }

  if (fs.existsSync(downloadKeyPath)) {
    const key = fs.readFileSync(downloadKeyPath, 'utf8').trim();
    if (key) {
      log(`reuse Web operation key: ${key}`);
      return key;
    }
  }

  const key = crypto.randomUUID();
  fs.writeFileSync(downloadKeyPath, `${key}\n`, { mode: 0o600 });
  log(`generate Web operation key: ${key}`);
  return key;
}

function copyServer() {
  log(`copy web server runtime: ${serverSource} -> ${runtimeServer}`);
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
  log(`startup root: ${root}`);
  if (!fs.existsSync(serverSource)) throw new Error(`missing server.mjs beside index.js: ${serverSource}`);
  if (!fs.existsSync(runtimeScript)) throw new Error(`missing hy2_fakeweb.sh beside index.js: ${runtimeScript}`);
  mkdirp(fileRoot);
  mkdirp(runtimeDir);
  mkdirp(downloadDir);
  ensureCertificate();
  ensureWebTorrentRuntime();
  const downloadKey = ensureDownloadKey();
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
    DOWNLOAD_KEY: downloadKey,
  };

  log(`spawn web server: ${runtimeServer}`);
  spawnChild('web', process.execPath, [runtimeServer], sharedEnv);

  log(`spawn HY2 runtime script: ${runtimeScript}`);
  spawnChild('runtime', 'bash', [runtimeScript], sharedEnv);
}

process.on('SIGTERM', () => shutdown(0));
process.on('SIGINT', () => shutdown(0));

try {
  main();
} catch (error) {
  console.error('[index.js] startup failed:', error);
  shutdown(1);
}