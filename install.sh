#!/bin/bash
set -e

# === 基础配置 ===
DOMAIN="trojan.frankcn.dpdns.org"
TUNNEL_NAME="trojan-tunnel"
CONFIG_DIR="/etc/cloudflared"
TUNNEL_DIR="${CONFIG_DIR}/tunnels"
TROJAN_PASSWORD="trojan-password"  # 替换为你的密码
API_TOKEN="你的_API_TOKEN"  # 替换为你的 Cloudflare API Token
ROOT_DOMAIN="frankcn.dpdns.org"
SUBDOMAIN="$DOMAIN"

echo "📦 安装依赖..."
apt update -y
apt install -y curl wget unzip qrencode jq

# ========== 停止旧服务 ==========
echo "🛑 停止旧服务..."
systemctl stop sb || true
systemctl stop cloudflared || true

# ========== 安装 cloudflared ==========
echo "📥 安装 cloudflared..."
wget -O /usr/local/bin/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
chmod +x /usr/local/bin/cloudflared

# ========== 安装 sing-box ==========
echo "📥 安装 sing-box..."
ARCH=$(uname -m)
SING_BOX_VERSION="1.8.5"
case "$ARCH" in
  x86_64) PLATFORM="linux-amd64" ;;
  aarch64) PLATFORM="linux-arm64" ;;
  armv7l) PLATFORM="linux-armv7" ;;
  *) echo "❌ 不支持的架构: $ARCH"; exit 1 ;;
esac

curl -LO "https://github.com/SagerNet/sing-box/releases/download/v${SING_BOX_VERSION}/sing-box-${SING_BOX_VERSION}-${PLATFORM}.tar.gz"
tar -zxf sing-box-${SING_BOX_VERSION}-${PLATFORM}.tar.gz
cp sing-box-${SING_BOX_VERSION}-${PLATFORM}/sing-box /usr/bin/sb
chmod +x /usr/bin/sb

# ========== Cloudflare 授权 ==========
echo "🌐 Cloudflare 授权..."

if [ -f "/root/.cloudflared/cert.pem" ]; then
