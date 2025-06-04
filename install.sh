#!/bin/bash
set -e

# === 基础配置 ===
DOMAIN="socks.frankdevcn.dpdns.org"
TUNNEL_NAME="socks-tunnel"
CONFIG_DIR="/etc/cloudflared"
TUNNEL_DIR="${CONFIG_DIR}/tunnels"

echo "📦 安装依赖..."
apt update -y
apt install -y curl wget unzip qrencode

# ========== 自动停止已有服务 ========== 
echo "🛑 检查 sb 服务状态..."
if systemctl list-units --full --all | grep -Fq 'sb.service'; then
    echo "🛑 sb.service 正在运行，正在停止..."
    systemctl stop sb || true
fi

echo "🛑 检查 cloudflared 服务状态..."
if systemctl list-units --full --all | grep -Fq 'cloudflared.service'; then
    echo "🛑 cloudflared.service 正在运行，正在停止..."
    systemctl stop cloudflared || true
fi

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

# ========== Cloudflare 登录授权 ========== 
echo "🌐 请在弹出的浏览器中登录 Cloudflare 账户以授权此主机..."
cloudflared tunnel login

# ========== 检查并删除已存在的 Tunnel ========== 
echo "🚧 检查 Tunnel 是否已存在..."
if cloudflared tunnel list | grep -Fq "$TUNNEL_NAME"; then
    echo "⚠️ Tunnel '$TUNNEL_NAME' 已存在，正在删除..."
    cloudflared tunnel delete "$TUNNEL_NAME"
fi

# ========== 创建 Tunnel ========== 
echo "🚧 正在创建 Tunnel: $TUNNEL_NAME ..."
cloudflared tunnel create "$TUNNEL_NAME"

# ========== 配置 sing-box ========== 
mkdir -p /etc/sb
cat <<EOF > /etc/sb/config.json
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "dns": {
    "servers": [
      { "address": "8.8.8.8" },
      { "address": "1.1.1.1" }
    ]
  },
  "inbounds": [
    {
      "type": "vless",
      "listen": "0.0.0.0",
      "listen_port": 2080,
      "users": [
        {
          "uuid": "123e4567-e89b-12d3-a456-426614174000",
          "flow": ""
        }
      ],
      "transport": {
        "type": "ws",
        "path": "/"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct"
    }
  ]
}
EOF

# ========== 写 cloudflared 配置 ========== 
TUNNEL_ID=$(cloudflared tunnel list | grep "$TUNNEL_NAME" | awk '{print $1}')

# 检查并创建必要的目录,并拷贝json文件到指定位置
if [ ! -d "$CONFIG_DIR" ]; then
    mkdir -p "$CONFIG_DIR"
    echo "Created config directory: $CONFIG_DIR"
fi
if [ ! -d "$TUNNEL_DIR" ]; then
    mkdir -p "$TUNNEL_DIR"
    echo "Created tunnel directory: $TUNNEL_DIR"
fi
cp /root/.cloudflared/${TUNNEL_ID}.json $TUNNEL_DIR


cat <<EOF > $CONFIG_DIR/config.yml
tunnel: $TUNNEL_ID
credentials-file: $TUNNEL_DIR/${TUNNEL_ID}.json

ingress:
  - hostname: socks.frankdevcn.dpdns.org
    service: http://127.0.0.1:2080
    originRequest:
      noTLSVerify: true
  - service: http_status:404
EOF

# ========== 配置 systemd 服务 ========== 
echo "🛠️ 写入 systemd 服务..."

cat <<EOF > /etc/systemd/system/sb.service
[Unit]
Description=sing-box proxy
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
ExecStart=/usr/local/bin/cloudflared --config /etc/cloudflared/config.yml tunnel run
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

# ========== 启动服务 ========== 
echo "🔄 启动 sb 和 cloudflared..."
systemctl daemon-reload
systemctl enable sb
systemctl enable cloudflared
systemctl restart sb
systemctl restart cloudflared

sleep 5

# ========== 更新CNAME记录 ========== 
API_TOKEN="57bYmP6bAIrsWG1L7PYEJ7rI7ATEASZXgEv-0vPl"
DOMAIN="frankdevcn.dpdns.org"      # 根域名
SUBDOMAIN="socks.frankdevcn.dpdns.org" # 要更新的子域名
TUNNEL_ID=$(jq -r '.TunnelID' "$(ls /root/.cloudflared/*.json | head -n 1)")

# ==== 开始执行 ====
echo "===== 开始更新 CNAME 记录 ====="

# 1. 获取 Zone ID
ZONE_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$DOMAIN" \
  -H "Authorization: Bearer $API_TOKEN" \
  -H "Content-Type: application/json" | jq -r '.result[0].id')

if [ -z "$ZONE_ID" ] || [ "$ZONE_ID" == "null" ]; then
  echo "❌ 获取 Zone ID 失败，请检查 DOMAIN 是否正确。"
  exit 1
fi

echo "✅ Zone ID: $ZONE_ID"

# 2. 获取 DNS Record ID
DNS_RECORD_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=CNAME&name=$SUBDOMAIN" \
  -H "Authorization: Bearer $API_TOKEN" \
  -H "Content-Type: application/json" | jq -r '.result[0].id')

if [ -z "$DNS_RECORD_ID" ] || [ "$DNS_RECORD_ID" == "null" ]; then
  echo "❌ 获取 DNS Record ID 失败，请检查 SUBDOMAIN 是否正确，且 CNAME 记录是否已存在。"
  exit 1
fi

echo "✅ DNS Record ID: $DNS_RECORD_ID"

# 3. 更新 DNS Record
RESPONSE=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$DNS_RECORD_ID" \
  -H "Authorization: Bearer $API_TOKEN" \
  -H "Content-Type: application/json" \
  --data '{
    "type": "CNAME",
    "name": "'"$SUBDOMAIN"'",
    "content": "'"$TUNNEL_ID"'.cfargotunnel.com",
    "ttl": 120,
    "proxied": true
}')

SUCCESS=$(echo "$RESPONSE" | jq -r '.success')

if [ "$SUCCESS" == "true" ]; then
  echo "🎉 成功更新 CNAME！"
else
  echo "❌ 更新失败，返回信息: $RESPONSE"
fi

# ========== 输出 Socks5 地址和二维码 ========== 
echo "✅ 安装完成，公网 Socks5 地址如下："
echo "🌍 socks5h://$DOMAIN:443"

echo "📱 正在生成 Socks5 代理二维码..."
qrencode -t ANSIUTF8 "socks5h://$DOMAIN:443"
