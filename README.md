# Moonroom

Moonroom 是一个轻量私有影视 WebApp：NodeJS 一键启动 HTTPS Web、React 前端、磁力任务管理、视频在线播放、文件删除和访问密钥。页面默认只加载封面和状态，只有点击播放时才请求视频文件。

- 自动生成 ECDSA prime256v1 自签证书（含 CN、SAN、法国上法兰西鲁贝地区字段、keyUsage、extendedKeyUsage）
- 证书默认有效期 365 天（1 年），提前 30 天自动续期
- Web 服务自动复用证书启用 HTTPS（证书不存在时降级为 HTTP）

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

`index.js` 会启动 HTTP Web 服务，并在同目录调用：

```bash
bash /home/container/hy2_fakeweb.sh
```

### 4. 设置环境变量

在服务器面板中填写自己的值，不要把真实值提交到仓库：

```bash
HTTP_LISTEN_PORT=YOUR_PORT
DOWNLOAD_MAX_ACTIVE=1
DOWNLOAD_MAX_QUEUE=3
TLS_CERT_IP=YOUR_SERVER_IP
TLS_CERT_CN=YOUR_SERVER_DOMAIN_OR_IP
TLS_CERT_DNS=YOUR_SERVER_DOMAIN
TLS_EARLY_RENEW_DAYS=30
```

Web 操作密钥默认开启。首次启动会自动生成并持久化到 `.npm/video/download_key.txt`，后续启动复用同一个密钥；如果需要手动指定，可以设置 `DOWNLOAD_KEY=YOUR_WEB_KEY` 覆盖默认值。

- `TLS_CERT_IP` - 证书 IP 地址（默认 51.75.118.151，必须设置为你的服务器真实 IP）
- `TLS_CERT_CN` - 证书 CN 名称（默认同 TLS_CERT_IP）
- `TLS_CERT_DNS` - 证书 DNS 名称（默认同 HY2_SNI）
- `TLS_EARLY_RENEW_DAYS` - 提前多少天续期（默认 30）

### 5. 访问页面

启动后访问（自签证书需要浏览器点击“继续访问”）：

```text
https://YOUR_SERVER_IP:YOUR_PORT/
```

### 6. 更新前端

修改 `web/` 后重新构建：

```bash
cd web
npm run build
```

然后上传新的 `dist/` 覆盖服务器上的旧版本。
