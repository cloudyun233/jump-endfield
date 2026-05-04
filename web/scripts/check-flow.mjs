import { existsSync, readFileSync, readdirSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const webRoot = path.resolve(here, '..');
const repoRoot = path.resolve(webRoot, '..');
const distRoot = path.join(repoRoot, 'dist');
const source = readFileSync(path.join(webRoot, 'src', 'App.jsx'), 'utf8');

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
assert(source.includes('https://hanime1.me/'), '页面包含 hanime1.me 外部入口');
assert(source.includes('rel="noopener noreferrer"'), 'hanime 外部入口使用 noopener noreferrer');
assert(!source.includes('<iframe'), '源码不内嵌第三方 iframe');
assert(!/location\.reload|window\.location/.test(source), '页面轮询不会触发浏览器整页刷新');
assert(source.includes('pendingFilesRef'), '片库变化会在播放中暂存，避免替换播放器');
assert(source.includes('video.src = serverAsset(file.url)'), '只有播放流程才挂载真实媒体地址');
assert(bundledJs.includes('/api/status'), '打包产物包含状态接口调用');
assert(bundledJs.includes('/api/downloads'), '打包产物包含下载任务接口调用');
assert(bundledJs.includes('/api/files/'), '打包产物包含删除影片接口调用');
