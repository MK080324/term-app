#!/usr/bin/env bash
# 卸载 term-app 的主机侧组件 (不动你的 Caddy/compose, 那两处手动回退)。
set -euo pipefail
[ "$(id -u)" = "0" ] || { echo "请用 sudo/root 运行"; exit 1; }

# 停掉所有 ttyd-* 以及两个网关服务
mapfile -t units < <(systemctl list-unit-files --no-legend 'ttyd-*.service' 2>/dev/null | awk '{print $1}')
units+=(oauth2-proxy.service totp-gate.service)
for u in "${units[@]}"; do
  systemctl disable --now "$u" 2>/dev/null || true
  rm -f "/etc/systemd/system/$u"
done
systemctl daemon-reload

rm -f /usr/local/bin/totp-gate
rm -rf /etc/webterm
# ttyd / oauth2-proxy 二进制与 webterm 用户保留 (可能别处在用); 如需彻底清理:
#   rm -f /usr/local/bin/ttyd /usr/local/bin/oauth2-proxy
#   userdel webterm
echo "已卸载主机侧组件。记得从 Caddyfile 删掉 term vhost 并重建 caddy。"
