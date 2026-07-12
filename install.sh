#!/usr/bin/env bash
#
# term-app 安装脚本 (在服务器上以 root 运行)。
#   sudo ./install.sh
#
# 干的事 (全部幂等, 可重复跑):
#   - 装依赖: ttyd 静态二进制、oauth2-proxy、用 docker 编译 totp-gate
#   - 按 config.env 生成 /etc/webterm/ 下的配置
#   - 写 systemd 服务并启动 (每个用户一个 ttyd + oauth2-proxy + totp-gate)
#
# 不碰你的 Caddy / docker-compose —— 那两处见 README, 手动改。
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="$SCRIPT_DIR/config.env"

# ---------- 0. 前置检查 ----------
[ "$(id -u)" = "0" ] || { echo "请用 sudo/root 运行"; exit 1; }
[ -f "$CONF" ] || { echo "找不到 $CONF —— 先 cp config.env.example config.env 并填好"; exit 1; }
# shellcheck disable=SC1090
source "$CONF"

for v in DOMAIN GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET OAUTH2_COOKIE_SECRET TOTP_GATE_HMAC_KEY; do
  [ -n "${!v:-}" ] || { echo "config.env 里 $v 为空"; exit 1; }
done
[ "${#USERS[@]}" -gt 0 ] || { echo "config.env 里 USERS 为空"; exit 1; }
: "${COOKIE_TTL_HOURS:=72}"
: "${OAUTH2_PROXY_VERSION:=v7.6.0}"
command -v docker >/dev/null || { echo "需要 docker (用于编译 totp-gate)"; exit 1; }
command -v curl   >/dev/null || { echo "需要 curl"; exit 1; }

# 校验每个用户: unix 用户存在、端口是数字
declare -a EMAILS UNIXES PORTS SECRETS
for entry in "${USERS[@]}"; do
  # shellcheck disable=SC2086
  read -r email unix port secret <<< "$entry"
  [ -n "$email" ] && [ -n "$unix" ] && [ -n "$port" ] && [ -n "$secret" ] \
    || { echo "USERS 某行字段不全: '$entry'"; exit 1; }
  id "$unix" >/dev/null 2>&1 || { echo "unix 用户不存在: $unix"; exit 1; }
  [[ "$port" =~ ^[0-9]+$ ]] || { echo "端口非法: $port"; exit 1; }
  EMAILS+=("$email"); UNIXES+=("$unix"); PORTS+=("$port"); SECRETS+=("$secret")
done

echo "==> 1. UTF-8 locale (保证中文字节正常)"
locale-gen en_US.UTF-8 >/dev/null 2>&1 || true
update-locale LANG=en_US.UTF-8 >/dev/null 2>&1 || true

echo "==> 2. 系统用户 webterm (跑 oauth2-proxy / totp-gate)"
id webterm >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin webterm

echo "==> 3. 安装 ttyd"
if ! command -v ttyd >/dev/null; then
  arch="$(uname -m)"   # x86_64 / aarch64
  curl -fsSL -o /usr/local/bin/ttyd \
    "https://github.com/tsl0922/ttyd/releases/latest/download/ttyd.${arch}"
  chmod +x /usr/local/bin/ttyd
fi
ttyd --version || true

echo "==> 4. 安装 oauth2-proxy ${OAUTH2_PROXY_VERSION}"
if ! command -v oauth2-proxy >/dev/null; then
  case "$(uname -m)" in
    x86_64)  oarch=amd64 ;;
    aarch64) oarch=arm64 ;;
    *) echo "未知架构 $(uname -m)"; exit 1 ;;
  esac
  tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/o.tgz" \
    "https://github.com/oauth2-proxy/oauth2-proxy/releases/download/${OAUTH2_PROXY_VERSION}/oauth2-proxy-${OAUTH2_PROXY_VERSION}.linux-${oarch}.tar.gz"
  tar -xzf "$tmp/o.tgz" -C "$tmp"
  install -m 0755 "$(find "$tmp" -name oauth2-proxy -type f | head -1)" /usr/local/bin/oauth2-proxy
  rm -rf "$tmp"
fi
oauth2-proxy --version || true

echo "==> 5. 编译 totp-gate (docker, 纯 stdlib 静态二进制)"
docker run --rm -v "$SCRIPT_DIR/totp-gate":/src -w /src golang:1.22-alpine \
  sh -c 'CGO_ENABLED=0 go build -trimpath -o /src/totp-gate .'
install -m 0755 "$SCRIPT_DIR/totp-gate/totp-gate" /usr/local/bin/totp-gate

echo "==> 6. 生成 /etc/webterm 配置"
mkdir -p /etc/webterm

# emails.txt
: > /etc/webterm/emails.txt
for e in "${EMAILS[@]}"; do echo "$e" >> /etc/webterm/emails.txt; done

# oauth2-proxy.cfg
cat > /etc/webterm/oauth2-proxy.cfg <<EOF
provider                  = "google"
client_id                 = "${GOOGLE_CLIENT_ID}"
client_secret             = "${GOOGLE_CLIENT_SECRET}"
redirect_url              = "https://${DOMAIN}/oauth2/callback"
cookie_secret             = "${OAUTH2_COOKIE_SECRET}"
cookie_domains            = ["${DOMAIN}"]
whitelist_domains         = ["${DOMAIN}"]
cookie_name               = "_wt_gauth"
cookie_expire             = "${COOKIE_TTL_HOURS}h"
cookie_refresh            = "0"
cookie_secure             = true
cookie_samesite           = "lax"
email_domains             = ["*"]
authenticated_emails_file = "/etc/webterm/emails.txt"
upstreams                 = ["http://127.0.0.1:9099"]
http_address              = "0.0.0.0:4180"
reverse_proxy             = true
pass_user_headers         = true
skip_provider_button      = true
EOF

# totp-gate.json (从 USERS 拼)
users_json=""
for i in "${!EMAILS[@]}"; do
  [ -n "$users_json" ] && users_json+=","
  users_json+=$(printf '\n    { "email": "%s", "upstream": "http://127.0.0.1:%s", "totp_secret": "%s" }' \
    "${EMAILS[$i]}" "${PORTS[$i]}" "${SECRETS[$i]}")
done
cat > /etc/webterm/totp-gate.json <<EOF
{
  "listen": "127.0.0.1:9099",
  "cookie_name": "_wt_totp",
  "cookie_hmac_key": "${TOTP_GATE_HMAC_KEY}",
  "cookie_ttl_hours": ${COOKIE_TTL_HOURS},
  "users": [${users_json}
  ]
}
EOF

chown -R webterm:webterm /etc/webterm
chmod 600 /etc/webterm/oauth2-proxy.cfg /etc/webterm/totp-gate.json
chmod 644 /etc/webterm/emails.txt

echo "==> 7. systemd 服务"
services=(totp-gate oauth2-proxy)

for i in "${!UNIXES[@]}"; do
  unix="${UNIXES[$i]}"; port="${PORTS[$i]}"
  home="$(getent passwd "$unix" | cut -d: -f6)"; : "${home:=/home/$unix}"
  cat > "/etc/systemd/system/ttyd-${unix}.service" <<EOF
[Unit]
Description=ttyd web terminal (${unix})
After=network.target

[Service]
User=${unix}
WorkingDirectory=${home}
Environment=LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 TERM=xterm-256color
# 想要"关页面/掉线后重连能续上会话", 把下面 bash --login 换成:  tmux new -A -s web
ExecStart=/usr/local/bin/ttyd -i 127.0.0.1 -p ${port} -W -t fontSize=14 bash --login
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
  services+=("ttyd-${unix}")
done

cat > /etc/systemd/system/totp-gate.service <<'EOF'
[Unit]
Description=webterm TOTP gate
After=network.target

[Service]
User=webterm
ExecStart=/usr/local/bin/totp-gate
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/oauth2-proxy.service <<'EOF'
[Unit]
Description=webterm oauth2-proxy (google)
After=network.target totp-gate.service

[Service]
User=webterm
ExecStart=/usr/local/bin/oauth2-proxy --config=/etc/webterm/oauth2-proxy.cfg
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now "${services[@]}"
systemctl restart "${services[@]}"

echo
echo "==> 主机侧完成。服务状态:"
systemctl --no-pager --lines=0 status "${services[@]}" 2>/dev/null | grep -E 'ttyd|oauth2|totp|Active' || true
echo
echo "还剩手动 3 步 (见 README 第 4~6 步):"
echo "  A. 给现有 Caddyfile 追加 caddy/term-vhost.caddy 那段 vhost"
echo "  B. 给 caddy 容器加 extra_hosts: host.docker.internal:host-gateway"
echo "  C. cd <你的tutor目录> && docker compose up -d   # 重建 caddy 生效"
echo
echo "别忘了: Google Console 加重定向 URI  https://${DOMAIN}/oauth2/callback"
