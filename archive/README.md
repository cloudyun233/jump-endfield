# VLESS+XTLS+REALITY 与 Hysteria2 一键安装脚本

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Shell Script](https://img.shields.io/badge/Shell-Bash-blue.svg)](https://www.gnu.org/software/bash/)

## ⚠️ 重要免责声明

**使用本脚本即表示您已阅读、理解并同意以下所有条款。**

- 本脚本仅用于**合法用途**，使用者必须确保符合当地法律法规
- 开发者明确反对任何非法网络活动
- 使用者需自行承担使用风险，开发者不对任何损失负责
- 脚本不会收集用户数据，所有配置和密钥均存储在本地

---

## 简介

本项目包含三个脚本，用于在Linux服务器上快速部署代理服务：
1. **official.bash** - Xray (VLESS+XTLS+REALITY) 和 Hysteria2 一键安装/卸载脚本
2. **candy.sh** - Caddy 反向代理服务器部署脚本
3. **sb.bash** - Sing-box 一键配置脚本，支持 VLESS Reality、Hysteria2、TUIC v5 协议

## 系统要求

- Linux操作系统 (支持 apt/dnf/yum/apk 包管理器的发行版)
- root 权限或 sudo 权限

## 快速开始

> **推荐：优先使用 Sing-box**，功能更丰富，支持 VLESS Reality、Hysteria2、TUIC v5 多种协议

### 1. Sing-box（推荐）

```bash
bash <(curl -Ls https://raw.githubusercontent.com/cloudyun233/jump-endfield/refs/heads/main/archive/sb.bash)
```

**功能选项：**
- 1) 安装/更新 Sing-box
- 2) 配置 VLESS Reality
- 3) 配置 Hysteria2
- 4) 配置 TUIC v5
- 5) 配置端口跳跃
- 6) 清除入栈配置

---

### 2. official.bash（官方 Xray/Hysteria2）

```bash
bash <(curl -Ls https://raw.githubusercontent.com/cloudyun233/jump-endfield/refs/heads/main/archive/official.bash)
```

**功能选项：**
- 1) 安装 VLESS + XTLS + REALITY (Xray)
- 2) 安装 Hysteria2
- 3) 删除 Xray
- 4) 删除 Hysteria2
- 5) IP 质量检测

---

### 3. Caddy 反向代理（可选）

需要已解析到服务器 IP 的域名。

```bash
bash <(curl -Ls https://raw.githubusercontent.com/cloudyun233/jump-endfield/refs/heads/main/archive/candy.sh)
```

## 配置信息

### Xray (VLESS+XTLS+REALITY)

- **配置文件**: `/usr/local/etc/xray/config.json`
- **安装目录**: `/usr/local/share/xray/`
- **默认端口**: 443 (TCP)
- **回弹端口**: 8443

### Hysteria2

- **配置文件**: `/etc/hysteria/config.yaml`
- **安装目录**: `/etc/hysteria/`
- **默认端口**: 443 (UDP)

### Sing-box

- **配置文件**: `/usr/local/etc/sing-box/config.json`
- **安装目录**: `/usr/local/etc/sing-box/`
- **支持协议**: VLESS Reality, Hysteria2, TUIC v5

### Caddy 反向代理

- **配置文件**: `/etc/caddy/Caddyfile`

---

## Clash Meta 客户端配置

### VLESS + XTLS + REALITY

```yaml
- name: 服务器名称
  type: vless
  server: 服务器IP/域名
  port: 端口（默认443）
  udp: true
  uuid: 脚本生成的UUID
  flow: xtls-rprx-vision
  packet-encoding: xudp
  tls: true
  servername: www.cho-kaguyahime.com
  alpn:
    - h2
    - http/1.1
  client-fingerprint: edge
  skip-cert-verify: true
  reality-opts:
    public-key: 脚本生成的X25519公钥
    short-id: "135246"
  network: tcp
```

### Hysteria2

```yaml
- name: 服务器名称
  type: hysteria2
  server: 服务器IP/域名
  port: 端口（默认443）
  password: 脚本生成的密码
  skip-cert-verify: true
  tfo: true
  # 可选配置
  # ports: 20000-20010  # 端口跳跃
  # obfs: salamander    # 混淆
  # obfs-password: 混淆密码
```

<!-- ### TUIC v5

```yaml
- name: 服务器名称
  type: tuic
  server: 服务器IP/域名
  port: 端口
  uuid: 脚本生成的UUID
  password: 脚本生成的密码
  congestion_control: bbr
  skip-cert-verify: true
``` -->

---

## 特殊场景

### 校园网绕过

在某些限制性网络环境中，可通过以下方式绕过限制：

1. 安装 Hysteria2 服务
2. 配置防火墙端口转发（以 nftables 为例）：

```bash
# 将53端口(DNS) UDP流量转发到443端口
sudo nft add rule inet nat prerouting udp dport 53 dnat to :443

# 67端口（DHCP服务器）
sudo nft add rule inet nat prerouting udp dport 67 dnat to :443

# 68端口（DHCP客户端）
sudo nft add rule inet nat prerouting udp dport 68 dnat to :443
```

3. 客户端使用53端口（或其他转发端口）连接
4. 若服务器重启，需要重新配置端口转发规则。或者参考下面的 nftables 配置以持久化。

---

## 维护

### 定时重启任务

以下 cron 任务可用于每天 UTC 20:00 自动重启服务器：

```
crontab -e
0 20 * * * /sbin/reboot
```

### nftables 端口转发

要启用 nftables 服务并配置端口转发，请执行以下命令：

```bash
# 编辑nftables配置文件
nano /etc/nftables.conf
# 添加端口转发规则
table inet nat {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;

        # 转发指定UDP端口到本机UDP 443端口（用于Hysteria2端口跳跃）
        udp dport {2053, 2083, 2087, 2096, 8443, 9443} dnat to :443

        # 大范围端口跳跃可用
        # udp dport 10240-20480 dnat to :443
        # 特殊需求可用
        # udp dport 53 dnat to :443
        # udp dport 67 dnat to :443
        # udp dport 68 dnat to :443
    }
}
# 启用nftables服务
sudo systemctl enable nftables
sudo systemctl restart nftables
```

可用于绕过某些网络环境中的端口限制。

## 许可证与致谢

- 本项目采用 MIT 许可证
- 致谢：
  - [Xray-project](https://github.com/XTLS/Xray-core) - 提供 Xray 核心
  - [Hysteria](https://github.com/apernet/hysteria) - 提供 Hysteria2 协议实现
  - [Sing-box](https://github.com/SagerNet/sing-box) - 提供多协议代理支持
  - [Caddy](https://github.com/caddyserver/caddy) - 提供反向代理功能
  - [IPQuality](https://github.com/xykt/IPQuality) - 提供 IP 质量检测服务

## 贡献

欢迎提交 Issue 和 Pull Request 来帮助改进此项目。
