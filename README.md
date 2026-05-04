# Moonroom

Moonroom 是一个轻量的私有影视 Web 页面：支持 React 前端、磁力任务管理、视频在线播放、文件删除和简单访问密钥。页面默认只加载封面和状态，只有点击播放时才请求视频文件，适合部署在 NodeJS 24 面板环境中。

推荐仓库名：`moonroom`

# 部署教程

## 1. 本地构建前端

```bash
cd web
npm install
npm run build
```

构建完成后，仓库根目录会生成 `dist/`。

## 2. 上传文件

把下面内容上传到服务器工作目录，例如 `/home/container`：

```text
index.js
server.mjs
archive/hy2_fakeweb.sh
dist/
```

## 3. 设置启动命令

面板 Startup Command 填：

```bash
node /home/container/index.js
```

## 4. 设置环境变量

在服务器面板中填写自己的值，不要把真实值提交到仓库：

```bash
TLS_CERT_IP=YOUR_SERVER_IP
HTTP_LISTEN_PORT=YOUR_PORT
DOWNLOAD_MAX_ACTIVE=1
DOWNLOAD_MAX_QUEUE=3
DOWNLOAD_KEY=YOUR_OPTIONAL_WEB_KEY
```

如果不需要 Web 操作密钥，可以留空 `DOWNLOAD_KEY`。

## 5. 访问页面

启动后访问：

```text
https://YOUR_SERVER_IP:YOUR_PORT/
```

使用自签证书时，浏览器会提示证书不受信任，手动继续访问即可。

## 6. 更新前端

修改 `web/` 后重新构建：

```bash
cd web
npm run build
```

然后上传新的 `dist/` 覆盖服务器上的旧版本。
