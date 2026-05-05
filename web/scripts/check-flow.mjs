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
assert(source.includes('href="/hanime/"'), 'Hanime 入口指向站内反代路由');
assert(!source.includes('https://hanime1.me/'), '页面不再直接暴露 hanime1.me 外部入口');
assert(source.includes('rel="noopener noreferrer"'), 'hanime 反代入口使用 noopener noreferrer');
assert(serverSource.includes('rewriteHanimeText'), 'Hanime 反代会改写 HTML/CSS/JS 内资源地址');
assert(serverSource.includes('rewriteHanimeCookie'), 'Hanime 反代会改写上游 Cookie 作用域');
assert(serverSource.includes('buildHanimeHeaders'), 'Hanime 反代按浏览器请求转发关键头部');
assert(serverSource.includes('rewriteHanimeHeaders'), 'Hanime 反代过滤并改写上游响应头');
assert(serverSource.includes('hanimeAssetPrefixes'), 'Hanime 反代接管常见根路径静态资源');
assert(serverSource.indexOf('if (await serveDist(req, res, pathname)) return;') < serverSource.indexOf('if (isHanimeProxyPath(pathname))'), '月光放映室静态资源优先于 Hanime 根路径反代');
assert(serverSource.includes("headers['Accept-Encoding'] = 'identity'"), 'Hanime 反代请求未压缩内容便于完整改写');
assert(serverSource.includes('body: hasProxyBody(req.method) ? req : undefined'), 'Hanime 反代会转发 POST 等请求体');
assert(serverSource.includes("target.origin"), 'Hanime 反代 Origin 头保持上游站点');
assert(serverSource.includes("'/cdn-cgi/'") && serverSource.includes('isHanimeProxyPath(pathname)'), '后端接管 Cloudflare 挑战路径');
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
