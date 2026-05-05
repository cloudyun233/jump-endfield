import { existsSync, readFileSync, readdirSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const webRoot = path.resolve(here, '..');
const repoRoot = path.resolve(webRoot, '..');
const distRoot = path.join(repoRoot, 'dist');
const source = readFileSync(path.join(webRoot, 'src', 'App.jsx'), 'utf8');
const serverSource = readFileSync(path.join(repoRoot, 'server.mjs'), 'utf8');

function assert(condition, message) {
  if (!condition) {
    console.error(`FAIL ${message}`);
    process.exitCode = 1;
  } else {
    console.log(`PASS ${message}`);
  }
}

const distIndex = path.join(distRoot, 'index.html');
const distAssets = existsSync(path.join(distRoot, 'assets'))
  ? readdirSync(path.join(distRoot, 'assets'))
  : [];
const jsAssets = distAssets.filter((name) => name.endsWith('.js'));
const cssAssets = distAssets.filter((name) => name.endsWith('.css'));
const bundledJs = jsAssets
  .map((name) => readFileSync(path.join(distRoot, 'assets', name), 'utf8'))
  .join('\n');
assert(existsSync(distIndex), '用户上传入口 dist/index.html 已生成');
assert(jsAssets.length > 0, 'React 业务脚本已打包到 dist/assets');
assert(cssAssets.length > 0, '样式已打包到 dist/assets');
assert(source.includes('preload="none"'), '视频标签使用 preload="none"');
assert(!source.includes('preload="metadata"'), '源码中没有 metadata 预加载');
assert(!source.includes('<source'), '源码中不渲染 source 标签');
assert(!source.includes('href="/proxy/"'), '前端不再提供反代入口');
assert(!existsSync(path.join(repoRoot, 'proxy-server.mjs')), 'proxy-server.mjs 已删除');
assert(!serverSource.includes('forwardToProxy'), 'server.mjs 不再包含反代转发函数');
assert(!serverSource.includes('isProxyPath'), 'server.mjs 不再匹配反代路径');
assert(!serverSource.includes('proxyPrefix'), 'server.mjs 不再使用反代前缀');
assert(!serverSource.includes('PROXY_PORT'), 'server.mjs 不再读取反代端口');

assert(!source.includes('<iframe'), '源码不内嵌第三方 iframe');
assert(!/location\.reload|window\.location/.test(source), '页面轮询不会触发浏览器整页刷新');
assert(source.includes('pendingFilesRef'), '片库变化会在播放中暂存，避免替换播放器');
assert(source.includes('video.src = serverAsset(file.url)'), '只有播放流程才挂载真实媒体地址');
assert(source.includes('accept="video/*,.mp4,.m4v,.webm,.mkv,.mov,.avi,.ts,.m3u8"'), '上传控件限制选择视频文件');
assert(source.includes("requestJson('/api/uploads'"), '前端通过上传接口提交本地视频');
assert(source.includes("'X-File-Name': selectedUpload.name"), '上传接口传递原始文件名');
assert(source.includes('inputRef.current.click()'), '上传按钮触发隐藏文件选择框');
assert(bundledJs.includes('/api/status'), '打包产物包含状态接口调用');
assert(bundledJs.includes('/api/downloads'), '打包产物包含下载任务接口调用');
assert(bundledJs.includes('/api/uploads'), '打包产物包含上传接口调用');
assert(bundledJs.includes('/api/files/'), '打包产物包含删除影片接口调用');
