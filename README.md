# Moonroom

Moonroom 是一个轻量私有影视 WebApp：NodeJS 一键启动 HTTPS Web、React 前端、磁力任务管理、视频在线播放、文件删除和访问密钥。页面默认只加载封面和状态，只有点击播放时才请求视频文件。

界面提供 hanime1.me 外部入口。

## 部署教程

### 1. 本地构建前端

```bash
cd web
npm install
npm run build
```

构建完成后，仓库根目录会生成 `dist/`。

### 2. 上传平铺运行文件

把下面内容放到 Linux 服务器同一个工作目录，例如 `/home/container`：

```text
index.js
server.mjs
hy2_fakeweb.sh
dist/
```

最终目录结构应类似：

```text
/home/container/index.js
/home/container/server.mjs
/home/container/hy2_fakeweb.sh
/home/container/dist/index.html
```

### 3. 设置启动命令

面板 Startup Command 填：

```bash
node /home/container/index.js
```

`index.js` 会启动 HTTPS Web 服务，并在同目录调用：

```bash
bash /home/container/hy2_fakeweb.sh
```

### 4. 设置环境变量

在服务器面板中填写自己的值，不要把真实值提交到仓库：

```bash
TLS_CERT_IP=YOUR_SERVER_IP
HTTP_LISTEN_PORT=YOUR_PORT
DOWNLOAD_MAX_ACTIVE=1
DOWNLOAD_MAX_QUEUE=3
```

Web 操作密钥默认开启。首次启动会自动生成并持久化到 `.npm/video/download_key.txt`，后续启动复用同一个密钥；如果需要手动指定，可以设置 `DOWNLOAD_KEY=YOUR_WEB_KEY` 覆盖默认值。

### 5. 访问页面

启动后访问：

```text
https://YOUR_SERVER_IP:YOUR_PORT/
```

使用自签证书时，浏览器会提示证书不受信任，手动继续访问即可。

### 6. 更新前端

修改 `web/` 后重新构建：

```bash
cd web
npm run build
```

然后上传新的 `dist/` 覆盖服务器上的旧版本。
