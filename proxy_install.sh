#!/bin/bash

if [ "$EUID" -ne 0 ]; then
  echo "❌ 请以 root 用户身份运行此脚本（使用 sudo）"
  exit 1
fi


# === 检查发行版类型 ===
if [ -f /etc/os-release ]; then
  . /etc/os-release
  DISTRO=$ID
else
  echo "❌ 无法识别系统类型，无法自动安装依赖"
  exit 1
fi

# === 选择安装命令 ===
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
  echo "❌ 当前系统 $DISTRO 暂不支持自动安装依赖，请手动安装：curl unzip socat jq cron qrencode uuidgen cloudflared"
  exit 1
fi


# === 检查依赖 ===
REQUIRED_CMDS=("curl" "unzip" "socat" "jq" "cron" "qrencode" "uuidgen" "cloudflared")
MISSING_CMDS=()

for cmd in "${REQUIRED_CMDS[@]}"; do
  if ! command -v "$cmd" &>/dev/null; then
    MISSING_CMDS+=("$cmd")
  fi
done

if [ "${#MISSING_CMDS[@]}" -gt 0 ]; then
  echo "🔧 检测到缺失依赖，正在安装: ${MISSING_CMDS[*]}"
  $UPDATE_CMD
  $INSTALL_CMD "${MISSING_CMDS[@]}"
else
  echo "✅ 所有依赖已满足"

# === cloudflared 安装逻辑（支持多架构） ===
if ! command -v cloudflared &>/dev/null; then
  echo "📦 cloudflared 未安装，开始检测系统与架构以选择安装方式..."

  if [ -f /etc/os-release ]; then
    . /etc/os-release
    DISTRO=$ID
    VERSION=$VERSION_CODENAME
  else
    echo "❌ 无法识别系统类型，默认采用二进制方式安装 cloudflared"
    DISTRO="unknown"
  fi

  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64) CFBIN="cloudflared-linux-amd64" ;;
    aarch64|arm64) CFBIN="cloudflared-linux-arm64" ;;
    armv7l|arm) CFBIN="cloudflared-linux-arm" ;;
    *) echo "❌ 不支持的架构: $ARCH"; exit 1 ;;
  esac

  if [[ "$DISTRO" =~ ^(ubuntu|debian)$ ]]; then
    echo "🌐 尝试使用 APT 安装 cloudflared"
    mkdir -p /usr/share/keyrings
    curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared $VERSION main" > /etc/apt/sources.list.d/cloudflared.list
    apt update
    apt install -y cloudflared || INSTALL_FAILED=true
  fi

  if ! command -v cloudflared &>/dev/null || [ "$INSTALL_FAILED" = true ]; then
    echo "📦 APT 安装失败，使用二进制方式安装 cloudflared ($CFBIN)"
    curl -L "https://github.com/cloudflare/cloudflared/releases/latest/download/$CFBIN" -o /usr/local/bin/cloudflared
    chmod +x /usr/local/bin/cloudflared
  fi

  if ! command -v cloudflared &>/dev/null; then
    echo "❌ cloudflared 安装失败，请手动安装 https://developers.cloudflare.com/cloudflared/"
    exit 1
  fi
else
  echo "✅ cloudflared 已安装"
fi


# === cloudflared 安装逻辑（补充） ===
if ! command -v cloudflared &>/dev/null; then
  echo "📦 正在尝试安装 cloudflared（二进制方式）..."
  curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o /usr/local/bin/cloudflared
  chmod +x /usr/local/bin/cloudflared
  if ! command -v cloudflared &>/dev/null; then
    echo "❌ cloudflared 安装失败，请手动安装 https://developers.cloudflare.com/cloudflared/"
    exit 1
  fi
else
  echo "✅ cloudflared 已安装"
fi

fi



set -e

UUID=$(uuidgen)
PORT=$(shuf -i 20001-59999 -n 1)
DOMAIN="sbu.frankcn.dpdns.org"
CF_API_TOKEN="suFUEdOxzo2yUvbN37qMSqWO08b2DtRTK2f4V1IP"  # 替换
EMAIL="frankcn@outlook.com"
WS_PATH="/vless"
TUNNEL_NAME="vless-ws"

SBOX_DIR="/etc/sing-box"
CONFIG_FILE="$SBOX_DIR/config.json"
CERT_PATH="$SBOX_DIR/cert.pem"
KEY_PATH="$SBOX_DIR/private.key"
LOG_PATH="/var/log/acme_renew.log"
CONFIG_YML="$HOME/.cloudflared/config.yml"

$UPDATE_CMD
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
