#!/bin/bash
set -e

echo "================================================================================"
echo "Cloudflared and Sing-box User-Local Installation Script"
echo "================================================================================"
echo "This script will install cloudflared and sing-box for the current user."
echo "It operates without requiring root privileges for the core application setup."
echo "All files (binaries, configurations, logs) will be stored within your"
echo "home directory, typically under '~/apps'."
echo "Services (cloudflared, sing-box) will run as background processes managed by you,"
echo "not via systemd."
echo "--------------------------------------------------------------------------------"
echo ""

# === 基础配置 ===
DOMAIN="socks.frankcn.dpdns.org"
TUNNEL_NAME="socks-tunnel"

# Define directory variables
USER_HOME=$(eval echo ~${SUDO_USER:-$USER})
APPS_BASE_DIR="${USER_HOME}/apps"
BIN_DIR="${APPS_BASE_DIR}/bin"
echo "--------------------------------------------------------------------------------"
echo "IMPORTANT: Please ensure that '${BIN_DIR}' is added to your PATH environment variable."
echo "You can do this by adding the following line to your ~/.bashrc or ~/.zshrc:"
echo ""
echo "  export PATH=\"${BIN_DIR}:\$PATH\""
echo ""
echo "Then, reload your shell (e.g., by running 'source ~/.bashrc' or 'source ~/.zshrc')."
echo "--------------------------------------------------------------------------------"
echo ""
CONFIG_BASE_DIR="${APPS_BASE_DIR}/config"
CLOUDFLARED_CONFIG_DIR="${CONFIG_BASE_DIR}/cloudflared"
CLOUDFLARED_TUNNELS_DIR="${CLOUDFLARED_CONFIG_DIR}/tunnels"
SB_CONFIG_DIR="${CONFIG_BASE_DIR}/sb"
LOG_DIR="${APPS_BASE_DIR}/logs"

# Create directories
mkdir -p "$BIN_DIR" "$CLOUDFLARED_TUNNELS_DIR" "$SB_CONFIG_DIR" "$LOG_DIR"
echo "--------------------------------------------------------------------------------"
echo "File Locations:"
echo "  Binaries will be installed to: ${BIN_DIR}"
echo "  Configurations will be stored in: ${CONFIG_BASE_DIR}"
echo "  Log files will be written to: ${LOG_DIR}"
echo "--------------------------------------------------------------------------------"
echo ""

# ========== 检查依赖 ==========
echo "🔎 检查依赖..."
REQUIRED_TOOLS=("curl" "wget" "unzip" "qrencode" "jq")
for tool in "${REQUIRED_TOOLS[@]}"; do
    if ! command -v "$tool" &> /dev/null; then
        echo "❌ Error: Required tool '$tool' is not installed."
        echo "   Please install it using your system's package manager (e.g., sudo apt install $tool) and try again."
        exit 1
    fi
done
echo "✅ 所有依赖已安装。"

# ========== 自动停止已有服务 ========== 
# Systemd commands for stopping services are removed as services are now run directly.
# Any pre-existing user-run processes would need to be manually stopped if they conflict.

# ========== 安装 cloudflared ========== 
echo "📥 安装 cloudflared..."
wget -O "${BIN_DIR}/cloudflared" https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
chmod +x "${BIN_DIR}/cloudflared"

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
cp sing-box-${SING_BOX_VERSION}-${PLATFORM}/sing-box "${BIN_DIR}/sb"
chmod +x "${BIN_DIR}/sb"

# ========== Cloudflare 登录授权 ========== 
echo "🌐 请在弹出的浏览器中登录 Cloudflare 账户以授权此主机..."
"${BIN_DIR}/cloudflared" --config "${CLOUDFLARED_CONFIG_DIR}/config.yml" tunnel login

# ========== 检查并删除已存在的 Tunnel ========== 
echo "🚧 检查 Tunnel 是否已存在..."
if "${BIN_DIR}/cloudflared" --config "${CLOUDFLARED_CONFIG_DIR}/config.yml" tunnel list | grep -Fq "$TUNNEL_NAME"; then
    echo "⚠️ Tunnel '$TUNNEL_NAME' 已存在，正在删除..."
    "${BIN_DIR}/cloudflared" --config "${CLOUDFLARED_CONFIG_DIR}/config.yml" tunnel delete "$TUNNEL_NAME"
fi

# ========== 创建 Tunnel ========== 
echo "🚧 正在创建 Tunnel: $TUNNEL_NAME ..."
"${BIN_DIR}/cloudflared" --config "${CLOUDFLARED_CONFIG_DIR}/config.yml" tunnel create "$TUNNEL_NAME"

# ========== 配置 sing-box ========== 
# mkdir -p /etc/sb # Already created by APPS_BASE_DIR logic
cat <<EOF > "${SB_CONFIG_DIR}/config.json"
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
TUNNEL_ID=$("${BIN_DIR}/cloudflared" --config "${CLOUDFLARED_CONFIG_DIR}/config.yml" tunnel list | grep "$TUNNEL_NAME" | awk '{print $1}')

# 检查并创建必要的目录,并拷贝json文件到指定位置
# Directories are created at the beginning of the script.
cp "${USER_HOME}/.cloudflared/${TUNNEL_ID}.json" "${CLOUDFLARED_TUNNELS_DIR}/${TUNNEL_ID}.json"


cat <<EOF > "${CLOUDFLARED_CONFIG_DIR}/config.yml"
tunnel: $TUNNEL_ID
credentials-file: "${CLOUDFLARED_TUNNELS_DIR}/${TUNNEL_ID}.json"

ingress:
  - hostname: socks.frankcn.dpdns.org
    service: http://127.0.0.1:2080
    originRequest:
      noTLSVerify: true
  - service: http_status:404
EOF

# ========== 启动服务 ========== 
echo "🚀 Starting sing-box as a background process..."
nohup "${BIN_DIR}/sb" run -c "${SB_CONFIG_DIR}/config.json" > "${LOG_DIR}/sb.log" 2>&1 &
SB_PID=$!
echo "Sing-box started with PID: $SB_PID. Log: ${LOG_DIR}/sb.log"

echo "🚀 Starting Cloudflare Tunnel as a background process..."
nohup "${BIN_DIR}/cloudflared" --config "${CLOUDFLARED_CONFIG_DIR}/config.yml" tunnel run > "${LOG_DIR}/cloudflared.log" 2>&1 &
CLOUDFLARED_PID=$!
echo "Cloudflared tunnel started with PID: $CLOUDFLARED_PID. Log: ${LOG_DIR}/cloudflared.log"

echo "✅ Services started in background."
echo "--------------------------------------------------------------------------------"
echo "Managing Background Processes:"
echo ""
echo "To check the status of cloudflared:"
echo "  ps aux | grep '[c]loudflared.*${CLOUDFLARED_CONFIG_DIR}'"
echo "  View logs: tail -f ${LOG_DIR}/cloudflared.log"
echo ""
echo "To check the status of sing-box:"
echo "  ps aux | grep '[s]b.*${SB_CONFIG_DIR}'"
echo "  View logs: tail -f ${LOG_DIR}/sb.log"
echo ""
echo "To stop cloudflared:"
echo "  pkill -f 'cloudflared.*--config.*${CLOUDFLARED_CONFIG_DIR}/config.yml'"
echo ""
echo "To stop sing-box:"
echo "  pkill -f 'sb.*run.*-c.*${SB_CONFIG_DIR}/config.json'"
echo "--------------------------------------------------------------------------------"
echo ""
sleep 5

# ========== 更新CNAME记录 ========== 
API_TOKEN="suFUEdOxzo2yUvbN37qMSqWO08b2DtRTK2f4V1IP"
DOMAIN="frankcn.dpdns.org"      # 根域名
SUBDOMAIN="socks.frankcn.dpdns.org" # 要更新的子域名

# Get the Tunnel ID from the JSON file in the user-specific tunnels directory
# This ensures we are using the ID of the tunnel managed by this script instance.
TUNNEL_ID_FOR_CNAME=$(jq -r '.TunnelID' "$(ls -t "${CLOUDFLARED_TUNNELS_DIR}"/*.json | head -n 1)")

if [ -z "$TUNNEL_ID_FOR_CNAME" ] || [ "$TUNNEL_ID_FOR_CNAME" == "null" ]; then
  echo "❌ Failed to retrieve Tunnel ID for CNAME update from JSON file."
  echo "Ensure a tunnel credential file exists in ${CLOUDFLARED_TUNNELS_DIR}"
  # Not exiting here, as the main TUNNEL_ID might still be valid for other parts or if CNAME update is optional.
  # However, the CNAME update itself will likely fail or use incorrect data.
fi

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
    "content": "'"$TUNNEL_ID_FOR_CNAME"'.cfargotunnel.com",
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
