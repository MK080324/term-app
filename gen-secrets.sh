#!/usr/bin/env bash
# 生成 term-app 需要的随机密钥。不写文件, 只打印, 你自己粘进 config.env。
#
# 用法:
#   ./gen-secrets.sh [DOMAIN] [标签1 标签2 ...]
# 例:
#   ./gen-secrets.sh term.gagamin.com alan mk
#
# 标签只用于 otpauth 二维码的显示名 (通常填 unix 用户名)。
set -euo pipefail

DOMAIN="${1:-term.example.com}"
shift || true
LABELS=("$@")
[ ${#LABELS[@]} -eq 0 ] && LABELS=(user1 user2)

need() { command -v "$1" >/dev/null 2>&1 || { echo "缺少命令: $1" >&2; exit 1; }; }
need openssl
need base32

echo "# ===== 粘进 config.env 的两个密钥 ====="
echo "OAUTH2_COOKIE_SECRET=\"$(openssl rand -base64 32)\""
echo "TOTP_GATE_HMAC_KEY=\"$(openssl rand -hex 32)\""
echo
echo "# ===== 每个用户的 TOTP 密钥 + otpauth (扫进 Aegis) ====="
for label in "${LABELS[@]}"; do
  secret="$(head -c 20 /dev/urandom | base32 | tr -d '=')"
  echo "[$label]"
  echo "  TOTP密钥(填进 config.env 的 USERS 第4列): $secret"
  echo "  otpauth (Aegis 扫码或手动输入): otpauth://totp/${DOMAIN}:${label}?secret=${secret}&issuer=${DOMAIN}&algorithm=SHA1&digits=6&period=30"
  echo
done
