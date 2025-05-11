#!/bin/bash

set -e

if [ "$EUID" -ne 0 ]; then
  echo "❌ 请以 root 用户身份运行此脚本（使用 sudo）"
  exit 1
fi

# === 系统识别 ===
if [ -f /etc/os-release ]; then
  . /etc/os-release
  DISTRO=$ID
  VERSION=$VERSION_CODENAME
else
  echo "❌ 无法识别系统类型"
  exit 1
fi

# === 包管理器 ===
if [[ "$DISTRO" =~ ^(ubuntu|debian)$ ]]; then
  INSTALL_CMD="apt install -y"
  UPDATE_CMD="apt update"
elif [[ "$DISTRO" =~ ^(centos|rhel|almalinux|rocky)$ ]]; then
  INSTALL_CMD="yum install -y"
  UPDATE_CMD="yum makecache"
elif [[ "$DISTRO" == "arch" ]]; then
  INSTALL_CMD="pacman -Syu --noconfirm"
  UPDATE_CMD="pacman -Sy"
else
  echo "❌ 不支持的系统: $DISTRO"
  exit 1
fi

# === 依赖 ===
REQUIRED_CMDS=("curl" "unzip" "socat" "jq" "cron" "qrencode" "uuidgen")
MISSING_CMDS=()
for cmd in "${REQUIRED_CMDS[@]}"; do
  if ! command -v "$cmd" &>/dev/null; then
    MISSING_CMDS+=("$cmd")
  fi
done
if [ "${#MISSING_CMDS[@]}" -gt 0 ]; then
  echo "🔧 安装缺失依赖: ${MISSING_CMDS[*]}"
  $UPDATE_CMD
  $INSTALL_CMD "${MISSING_CMDS[@]}"
else
  echo "✅ 所有依赖已满足"
fi

# === 安装 cloudflared ===
if ! command -v cloudflared &>/dev/null; then
  echo "📦 安装 cloudflared..."
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64) CFBIN="cloudflared-linux-amd64" ;;
    aarch64|arm64) CFBIN="cloudflared-linux-arm64" ;;
    armv7l|arm) CFBIN="cloudflared-linux-arm" ;;
    *) echo "❌ 不支持的架构: $ARCH"; exit 1 ;;
  esac
  curl -L "https://github.com/cloudflare/cloudflared/releases/latest/download/$CFBIN" -o /usr/local/bin/cloudflared
  chmod +x /usr/local/bin/cloudflared
fi
echo "✅ cloudflared 已安装"

# === 变量配置 ===
UUID=$(uuidgen)
PORT=$(shuf -i 20001-59999 -n 1)
DOMAIN="sbu.frankcn.dpdns.org"
CF_API_TOKEN="suFUEdOxzo2yUvbN37qMSqWO08b2DtRTK2f4V1IP"
EMAIL="frankcn@outlook.com"
WS_PATH="/vless"
TUNNEL_NAME="vless-ws"

SBOX_DIR="/etc/sing-box"
CONFIG_FILE="$SBOX_DIR/config.json"
CERT_PATH="$SBOX_DIR/cert.pem"
KEY_PATH="$SBOX_DIR/private.key"
LOG_PATH="/var/log/acme_renew.log"
CONFIG_YML="$HOME/.cloudflared/config.yml"

# === 安装 acme.sh 并使用 Let's Encrypt ===
if [ ! -f /root/.acme.sh/acme.sh ]; then
  curl https://get.acme.sh | sh
fi

export CF_Token="$CF_API_TOKEN"
export CF_Email="$EMAIL"

/root/.acme.sh/acme.sh --set-default-ca --server letsencrypt
/root/.acme.sh/acme.sh --register-account -m "$EMAIL"
/root/.acme.sh/acme.sh --issue --dns dns_cf -d "$DOMAIN" --keylength ec-256

mkdir -p "$SBOX_DIR"
/root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
  --key-file "$KEY_PATH" \
  --fullchain-file "$CERT_PATH" \
  --reloadcmd "systemctl restart sing-box && systemctl restart cloudflared@$TUNNEL_NAME >> $LOG_PATH 2>&1"

# === 安装 sing-box ===
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

# === Cloudflare Tunnel ===
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
ExecStart=/usr/local/bin/cloudflared tunnel run %i
Restart=on-failure
User=$(whoami)

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reexec
systemctl daemon-reload
systemctl enable cloudflared@"$TUNNEL_NAME"
systemctl restart cloudflared@"$TUNNEL_NAME"

# === 展示导入链接 ===
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
