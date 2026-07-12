# term-app

浏览器里的服务器终端，效果 = 用终端模拟器 ssh 上去：满屏自适应、鼠标点击聚焦、中文输入、滚轮滚动。

**两层认证**：Google 第三方登录（邮箱白名单） + 独立于 Google 的 TOTP（Aegis / Google Authenticator）。cookie 默认 3 天。支持**按 Google 身份分流到不同的 unix 用户**。

## 架构

```
浏览器 ─HTTPS→ Caddy(你现有的容器, 加一个 vhost)
        └─host-gateway:4180→ oauth2-proxy(Google 登录 + 邮箱白名单, cookie)
             └─127.0.0.1:9099→ totp-gate(按邮箱选人 + 校验各自 TOTP, cookie)
                  └─127.0.0.1:76xx→ ttyd(以对应 unix 用户起 bash --login)
```

- **ttyd** 跑在宿主机、以真实 unix 用户起登录 shell —— 所以是"真正 ssh 上那个用户"，不是容器里的假用户。前端是 xterm.js，满屏/中文/滚轮都是它的默认能力。
- **oauth2-proxy** 只有它对 caddy 容器可见（`0.0.0.0:4180`）；`totp-gate` 和各 `ttyd` 都只绑 `127.0.0.1`，公网够不到。
- **totp-gate**（本仓库 `totp-gate/main.go`，~200 行纯 stdlib Go）读 `X-Forwarded-Email` 选对应用户 + 密钥，自己发/验 HMAC 签名 cookie。

## 组件与端口

| 组件 | 监听 | 说明 |
|------|------|------|
| oauth2-proxy | `0.0.0.0:4180` | 唯一让 caddy 容器可达的口；**不要**加进云安全组 |
| totp-gate | `127.0.0.1:9099` | 第二层 TOTP |
| ttyd (每用户一个) | `127.0.0.1:76xx` | config.env 里分配 |

⚠️ `4180 / 9099 / 76xx` 都**不要**放进阿里云安全组，只保留 `80/443/22`。公网只经 Caddy(443) 进来。

---

## 部署步骤

### 1. 拉仓库 + 填配置

```bash
git clone git@github.com:MK080324/term-app.git
cd term-app
cp config.env.example config.env
```

### 2. 生成密钥并填进 config.env

```bash
./gen-secrets.sh term.gagamin.com alan mk
```

把打印出来的 `OAUTH2_COOKIE_SECRET`、`TOTP_GATE_HMAC_KEY` 填进 `config.env`；
每个用户的 TOTP 密钥填进 `USERS` 数组第 4 列；打印的 `otpauth://...` 用手机 **Aegis 扫码或手动录入**。
再把 `DOMAIN`、`GOOGLE_CLIENT_ID/SECRET`、`USERS` 的邮箱↔用户↔端口填好。

### 3. 跑安装脚本（装依赖 + 起主机侧服务）

```bash
sudo ./install.sh
```

自动：装 ttyd、oauth2-proxy，用 docker 编译 totp-gate，写好 `/etc/webterm/` 配置和 systemd 服务并启动。
**依赖**：只需要机器上有 `docker` 和 `curl`（编译 totp-gate 用 docker，无需装 Go）。

### 4. 接进你现有的 Caddy（手动，2 处小改）

**a.** 把 `caddy/term-vhost.caddy` 那段（域名换成你的 `DOMAIN`）追加到现有 Caddyfile 末尾，例如 `/root/tutor-app/Caddyfile`：

```caddyfile
term.gagamin.com {
	reverse_proxy host.docker.internal:4180
}
```

**b.** 给 caddy 容器加宿主机访问能力。编辑该 compose 文件（如 `/root/tutor-app/docker-compose.yml`），在 **caddy 服务**下加：

```yaml
  caddy:
    # ...原有不动...
    extra_hosts:
      - "host.docker.internal:host-gateway"
```

> 确认 Caddyfile 是**挂载**进容器的（compose 里有类似 `- ./Caddyfile:/etc/caddy/Caddyfile`），否则第 a 步改动不生效。

**c.** 重建 caddy 生效（只重建 caddy，其它服务不动）：

```bash
cd /root/tutor-app && docker compose up -d
```

### 5. Google Cloud Console

- OAuth client 的**已授权重定向 URI** 加：`https://<DOMAIN>/oauth2/callback`
- 若应用还在 **Testing** 状态，把白名单里的邮箱都加进**测试用户**。

### 6. 验证

浏览器开 `https://<DOMAIN>` → Google 登录 → 6 位 TOTP → 落到对应用户的满屏终端。

---

## 常用运维

```bash
# 看日志
journalctl -u oauth2-proxy -u totp-gate -f
journalctl -u ttyd-alan -f

# 改了 config.env 后重新应用
sudo ./install.sh

# 会话持久化: 关页面/断线重连能续上
#   把 ttyd-*.service 里的  bash --login  换成  tmux new -A -s web
#   sudo systemctl daemon-reload && sudo systemctl restart ttyd-<user>

# 卸载主机侧组件
sudo ./uninstall.sh
```

## 安全说明

- `config.env` 含明文密钥，已被 `.gitignore` 忽略，**永不进仓库**。
- 第二层 `totp-gate` 坐在 Google 认证之后：即便它有 bug，攻击者也得先过 Google 账号 —— 纵深防御。
- 高端口全绑内网 / 不进安全组；对外只有 Caddy 的 443。
