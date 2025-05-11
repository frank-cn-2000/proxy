#!/bin/bash

set -e

UUID="suFUEdOxzo2yUvbN37qMSqWO08b2DtRTK2f4V1IP"
PORT=23523
DOMAIN="sbu.frankcn.dpdns.org"
CF_API_TOKEN="你的CF_API_Token"  # 替换
EMAIL="frank.cn@outlook.com"
WS_PATH="/vless"
TUNNEL_NAME="vless-ws"

SBOX_DIR="/etc/sing-box"
CONFIG_FILE="$SBOX_DIR/config.json"
CERT_PATH="$SBOX_DIR/cert.pem"
KEY_PATH="$SBOX_DIR/private.key"
LOG_PATH="/var/log/acme_renew.log"
CONFIG_YML="$HOME/.cloudflared/config.yml"

apt update
apt install -y curl unzip socat jq cron qrencode cloudflared

if ! command -v acme.sh &>/dev/null; then
  curl https://get.acme.sh | sh
  source ~/.bashrc
fi

export CF_Token="$CF_API_TOKEN"
export CF_Email="$EMAIL"
~/.acme.sh/acme.sh --issue --dns dns_cf -d "$DOMAIN" --keylength ec-256
mkdir -p "$SBOX_DIR"
~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
  --key-file "$KEY_PATH" \
  --fullchain-file "$CERT_PATH" \
  --reloadcmd "systemctl restart sing-box && systemctl restart cloudflared@$TUNNEL_NAME >> $LOG_PATH 2>&1"

curl -Lo /tmp/sing-box.zip https://github.com/SagerNet/sing-box/releases/latest/download/sing-box-linux-amd64.zip
unzip -o /tmp/sing-box.zip -d /tmp/
install -m 755 /tmp/sing-box /usr/local/bin/sing-box

cat > "$CONFIG_FILE" <<EOF
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [{
    "type": "vless",
    "tag": "vless-ws",
    "listen": "::",
    "listen_port": $PORT,
    "users": [{ "uuid": "$UUID" }],
    "tls": {
      "enabled": true,
      "server_name": "$DOMAIN",
      "certificate_path": "$CERT_PATH",
      "key_path": "$KEY_PATH"
    },
    "transport": {
      "type": "ws",
      "path": "$WS_PATH"
    }
  }],
  "outbounds": [{ "type": "direct" }]
}
EOF

cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=Sing-box Service
After=network.target

[Service]
ExecStart=/usr/local/bin/sing-box run -c $CONFIG_FILE
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable sing-box
systemctl restart sing-box

cloudflared login || true
cloudflared tunnel delete "$TUNNEL_NAME" || true
rm -f "$HOME/.cloudflared/$TUNNEL_NAME.json"
cloudflared tunnel create "$TUNNEL_NAME"
TUNNEL_ID=$(cloudflared tunnel list -o json | jq -r ".[] | select(.name==\"$TUNNEL_NAME\") | .id")
TUNNEL_ID_FILE="$HOME/.cloudflared/$TUNNEL_ID.json"

cat > "$CONFIG_YML" <<EOF
tunnel: $TUNNEL_ID
credentials-file: $TUNNEL_ID_FILE

ingress:
  - hostname: $DOMAIN
    service: https://localhost:$PORT
  - service: http_status:404
EOF

cloudflared tunnel route dns "$TUNNEL_NAME" "$DOMAIN"

cat > /etc/systemd/system/cloudflared@$TUNNEL_NAME.service <<EOF
[Unit]
Description=Cloudflared Tunnel %i
After=network.target

[Service]
ExecStart=/usr/bin/cloudflared tunnel run %i
Restart=on-failure
User=$(whoami)

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reexec
systemctl daemon-reload
systemctl enable cloudflared@"$TUNNEL_NAME"
systemctl restart cloudflared@"$TUNNEL_NAME"

LINK="vless://$UUID@$DOMAIN:443?encryption=none&security=tls&type=ws&host=$DOMAIN&path=$WS_PATH#VLESS-CFTunnel"

echo
echo "✅ 已完成部署"
echo "📌 UUID: $UUID"
echo "📦 端口: $PORT"
echo "🌐 子域名: $DOMAIN"
echo "📂 路径: $WS_PATH"
echo
echo "🔗 导入链接:"
echo "$LINK"
qrencode -t ANSIUTF8 "$LINK"
