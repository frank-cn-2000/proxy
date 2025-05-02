#!/bin/bash
set -e

# === 基础配置 ===
DOMAIN="trojan.frankcn.dpdns.org"
TUNNEL_NAME="trojan-tunnel"
CONFIG_DIR="/etc/cloudflared"
TUNNEL_DIR="${CONFIG_DIR}/tunnels"
TROJAN_PASSWORD="5RmYpsF02tP9bZK1Dbcc76RrLGCtzajB"  # 替换为你的密码

echo "📦 安装依赖..."
apt update -y
apt install -y curl wget unzip qrencode jq

# ========== 停止旧服务 ==========
echo "🛑 停止旧服务..."
systemctl stop sb || true
systemctl stop cloudflared || true

# ========== 安装 cloudflared ==========
echo "📅 安装 cloudflared..."
wget -O /usr/local/bin/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
chmod +x /usr/local/bin/cloudflared

# ========== 安装 sing-box ==========
echo "📅 安装 sing-box..."
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

# ========== Cloudflare 登陆授权 ==========
echo "🌐 Cloudflare 授权..."
cloudflared tunnel login

# ========== 删除旧 Tunnel ==========
if cloudflared tunnel list | grep -Fq "$TUNNEL_NAME"; then
    echo "⚠️ Tunnel '$TUNNEL_NAME' 已存在，删除中..."
    cloudflared tunnel delete "$TUNNEL_NAME"
fi

# ========== 创建新 Tunnel ==========
cloudflared tunnel create "$TUNNEL_NAME"

# ========== 获取 Tunnel ID ==========
TUNNEL_ID=$(cloudflared tunnel list --output json | jq -r '.[] | select(.name=="'$TUNNEL_NAME'") | .id')

# ========== 配置 sing-box (Trojan) ==========
mkdir -p /etc/sb
cat <<EOF > /etc/sb/config.json
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [
    {
      "type": "trojan",
      "listen": "0.0.0.0",
      "listen_port": 8443,
      "users": [{ "password": "$TROJAN_PASSWORD" }]
    }
  ],
  "outbounds": [{ "type": "direct" }]
}
EOF

# ========== 配置 cloudflared ==========
mkdir -p "$CONFIG_DIR" "$TUNNEL_DIR"
cp /root/.cloudflared/${TUNNEL_ID}.json "$TUNNEL_DIR"

cat <<EOF > $CONFIG_DIR/config.yml
tunnel: $TUNNEL_ID
credentials-file: $TUNNEL_DIR/${TUNNEL_ID}.json

ingress:
  - hostname: $DOMAIN
    service: https://localhost:8443
    originRequest:
      noTLSVerify: true
  - service: http_status:404
EOF

# ========== systemd 服务 ==========
echo "🛠️ 写入 systemd 服务..."

cat <<EOF > /etc/systemd/system/sb.service
[Unit]
Description=sing-box trojan
After=network.target

[Service]
ExecStart=/usr/bin/sb run -c /etc/sb/config.json
Restart=on-failure
User=root
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

cat <<EOF > /etc/systemd/system/cloudflared.service
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
ExecStart=/usr/local/bin/cloudflared --config /etc/cloudflared/config.yml tunnel run "$TUNNEL_NAME"
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

# ========== 启动服务 ==========
echo "🔄 启动服务..."
systemctl daemon-reload
systemctl enable sb cloudflared
systemctl restart sb cloudflared

sleep 5

# ========== 更新 DNS CNAME ==========
API_TOKEN="BDNFhb_qCI19R8h9x8IOaTlTCTWTbGo_ZzOxRocn"  # 记得替换
ROOT_DOMAIN="frankcn.dpdns.org"
SUBDOMAIN="$DOMAIN"

ZONE_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$ROOT_DOMAIN" \
  -H "Authorization: Bearer $API_TOKEN" -H "Content-Type: application/json" | jq -r '.result[0].id')

DNS_RECORD_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=CNAME&name=$SUBDOMAIN" \
  -H "Authorization: Bearer $API_TOKEN" -H "Content-Type: application/json" | jq -r '.result[0].id')

if [ "$DNS_RECORD_ID" == "null" ] || [ -z "$DNS_RECORD_ID" ]; then
  echo "🌟 创建 DNS CNAME  记录..."
  curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
    -H "Authorization: Bearer $API_TOKEN" -H "Content-Type: application/json" \
    --data '{
      "type": "CNAME",
      "name": "'"$SUBDOMAIN"'",
      "content": "'"$TUNNEL_ID"'.cfargotunnel.com",
      "ttl": 120,
      "proxied": true
    }'
else
  echo "🔄 更新 DNS CNAME 记录..."
  curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$DNS_RECORD_ID" \
    -H "Authorization: Bearer $API_TOKEN" -H "Content-Type: application/json" \
    --data '{
      "type": "CNAME",
      "name": "'"$SUBDOMAIN"'",
      "content": "'"$TUNNEL_ID"'.cfargotunnel.com",
      "ttl": 120,
      "proxied": true
    }'
fi

# ========== 输出 Trojan 地址和二维码 ==========
TROJAN_LINK="trojan://$TROJAN_PASSWORD@$DOMAIN:443?peer=$DOMAIN#MyTrojan"
echo "✅ Trojan 代理链接：$TROJAN_LINK"
echo "📱 生成二维码："
qrencode -t ANSIUTF8 "$TROJAN_LINK"
