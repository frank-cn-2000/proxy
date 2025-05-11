#!/bin/bash

# VLESS + sing-box + Cloudflare Tunnel + Let's Encrypt (via Cloudflare)
# Fully compatible with Ubuntu 24.04 LTS
# Author: AI Assistant (Relies on server-side cloudflared to fetch cert)

# --- USER CONFIGURABLE VARIABLES ---
# !!! 请在运行脚本前修改以下变量 !!!
# ------------------------------------
# 将 YOUR_DOMAIN 替换为您的域名 (例如：vless.yourdomain.com)
# 确保此域名已在 Cloudflare 解析，或者至少 NS 记录指向 Cloudflare。
YOUR_DOMAIN="frankcn.dpdns.org"
# ------------------------------------
# VLESS_UUID, SINGBOX_PORT, 和 WS_PATH 将在脚本运行时自动随机生成。
# --- END OF USER CONFIGURABLE VARIABLES ---


# --- Global Variables (populated later) ---
VLESS_UUID=""
SINGBOX_PORT=""
WS_PATH=""
DOMAIN="" # Will be set from YOUR_DOMAIN
TUNNEL_ID="" # Will be set during Cloudflare Tunnel creation
TUNNEL_NAME="" # Will be set during Cloudflare Tunnel creation
CLOUDFLARED_CRED_DIR="/root/.cloudflared" # Standard path for root user

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- Helper Functions ---
log_info() {
    echo -e "${BLUE}[INFO] ${NC}$1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS] ${NC}$1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING] ${NC}$1"
}

log_error() {
    echo -e "${RED}[ERROR] ${NC}$1" >&2
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "此脚本需要 root 权限运行。请使用 'sudo bash $0'。"
        exit 1
    fi
    # Ensure cloudflared credentials directory exists and has correct permissions for root
    mkdir -p "$CLOUDFLARED_CRED_DIR"
    chmod 700 "$CLOUDFLARED_CRED_DIR"
}

validate_and_set_configs() {
    log_info "正在验证和设置配置..."
    if [[ -z "$YOUR_DOMAIN" || "$YOUR_DOMAIN" == "your.domain.com" || "$YOUR_DOMAIN" == *"YOUR_DOMAIN"* ]]; then
        log_error "请编辑脚本文件，将顶部的 'YOUR_DOMAIN' 变量设置为您自己的域名。"
        exit 1
    fi
    DOMAIN="$YOUR_DOMAIN"

    if ! [[ "$DOMAIN" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        log_error "配置的域名 '$DOMAIN' 格式不正确。"
        exit 1
    fi
    log_info "将使用域名: $DOMAIN"

    VLESS_UUID=$(uuidgen)
    log_info "随机生成的 VLESS UUID: $VLESS_UUID"

    SINGBOX_PORT=$(shuf -i 10000-65535 -n 1)
    log_info "随机生成的 sing-box 本地端口: $SINGBOX_PORT"

    WS_PATH="/$(uuidgen | cut -d'-' -f1)-$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 8)"
    log_info "随机生成的 WebSocket 路径: $WS_PATH"
}


detect_arch() {
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) ARCH_ALT="amd64" ;;
        aarch64) ARCH_ALT="arm64" ;;
        armv7l) ARCH_ALT="armv7" ;;
        *)
            log_error "不支持的系统架构: $ARCH"
            exit 1
            ;;
    esac
    log_info "检测到系统架构: $ARCH ($ARCH_ALT)"
}

install_dependencies() {
    log_info "更新软件包列表并安装依赖..."
    apt update >/dev/null 2>&1
    apt install -y curl jq unzip uuid-runtime qrencode >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        log_error "依赖安装失败。请检查网络连接和apt源。"
        exit 1
    fi
    log_success "依赖安装完成。"
}

install_singbox() {
    log_info "正在安装 sing-box..."
    SINGBOX_LATEST_URL="https://api.github.com/repos/SagerNet/sing-box/releases/latest"
    SINGBOX_VERSION_TAG=$(curl -sL "$SINGBOX_LATEST_URL" | jq -r ".tag_name")
    
    if [ -z "$SINGBOX_VERSION_TAG" ] || [ "$SINGBOX_VERSION_TAG" == "null" ]; then
        log_error "无法获取最新的 sing-box 版本标签。"
        SINGBOX_VERSION="1.9.0" # Example fallback
        log_warning "使用备用版本号: $SINGBOX_VERSION (标签: v$SINGBOX_VERSION)"
        SINGBOX_VERSION_TAG="v${SINGBOX_VERSION}" # Ensure tag has 'v'
    else
        SINGBOX_VERSION=$(echo "$SINGBOX_VERSION_TAG" | sed 's/v//')
        log_info "获取到最新 sing-box 版本: $SINGBOX_VERSION (标签: $SINGBOX_VERSION_TAG)"
    fi

    DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/${SINGBOX_VERSION_TAG}/sing-box-${SINGBOX_VERSION}-linux-${ARCH_ALT}.tar.gz"
    
    log_info "正在从 $DOWNLOAD_URL 下载 sing-box..."
    curl -Lo sing-box.tar.gz "$DOWNLOAD_URL"
    if [ $? -ne 0 ]; then
        log_error "sing-box 下载失败 (URL: $DOWNLOAD_URL)。"
        if [ "$ARCH_ALT" == "armv7" ]; then
            ALT_DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/${SINGBOX_VERSION_TAG}/sing-box-${SINGBOX_VERSION}-linux-${ARCH_ALT}hf.tar.gz"
            log_info "尝试 armv7hf 下载链接: $ALT_DOWNLOAD_URL"
            curl -Lo sing-box.tar.gz "$ALT_DOWNLOAD_URL"
            if [ $? -ne 0 ]; then
                 log_error "armv7hf 下载也失败了。"
                 exit 1
            fi
        else
            exit 1
        fi
    fi

    if ! tar -tzf sing-box.tar.gz > /dev/null 2>&1; then
        log_error "下载的 sing-box 文件不是有效的 tar.gz 压缩包。可能是下载链接有误或架构不支持。"
        rm -f sing-box.tar.gz
        exit 1
    fi

    ACTUAL_EXTRACT_DIR=$(tar -tzf sing-box.tar.gz | head -n1 | cut -f1 -d"/")
    if [ -z "$ACTUAL_EXTRACT_DIR" ]; then
        log_error "无法确定解压后的目录名。"
        rm -f sing-box.tar.gz
        exit 1
    fi
    
    tar -xzf sing-box.tar.gz
    if [ ! -f "${ACTUAL_EXTRACT_DIR}/sing-box" ]; then
        log_error "解压后未找到 sing-box 可执行文件于 '${ACTUAL_EXTRACT_DIR}/sing-box'。目录结构可能已更改。"
        ls -lah 
        rm -rf sing-box.tar.gz "${ACTUAL_EXTRACT_DIR}"
        exit 1
    fi

    mv "${ACTUAL_EXTRACT_DIR}/sing-box" /usr/local/bin/
    chmod +x /usr/local/bin/sing-box
    rm -rf sing-box.tar.gz "${ACTUAL_EXTRACT_DIR}/"

    mkdir -p /etc/sing-box/
    
    cat > /etc/sing-box/config.json <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "127.0.0.1",
      "listen_port": ${SINGBOX_PORT},
      "users": [
        {
          "uuid": "${VLESS_UUID}",
          "flow": "" 
        }
      ],
      "transport": {
        "type": "ws",
        "path": "${WS_PATH}",
        "max_early_data": 0,
        "early_data_header_name": "Sec-WebSocket-Protocol"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF
    log_success "sing-box 安装和配置完成。"
}

install_cloudflared() {
    log_info "正在安装 Cloudflared..."
    CLOUDFLARED_LATEST_VERSION_URL="https://api.github.com/repos/cloudflare/cloudflared/releases/latest"
    CLOUDFLARED_VERSION_TAG=$(curl -sL $CLOUDFLARED_LATEST_VERSION_URL | jq -r '.tag_name')

    if [ -z "$CLOUDFLARED_VERSION_TAG" ] || [ "$CLOUDFLARED_VERSION_TAG" == "null" ]; then
        log_warning "无法获取最新的 Cloudflared 版本标签。将尝试使用通用下载链接。"
        DOWNLOAD_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH_ALT}"
    else
        log_info "获取到最新 Cloudflared 版本标签: $CLOUDFLARED_VERSION_TAG"
        DOWNLOAD_URL="https://github.com/cloudflare/cloudflared/releases/download/${CLOUDFLARED_VERSION_TAG}/cloudflared-linux-${ARCH_ALT}"
    fi
    
    curl -Lo /usr/local/bin/cloudflared "$DOWNLOAD_URL"
    if [ $? -ne 0 ]; then
        log_error "Cloudflared 下载失败。"
        exit 1
    fi
    chmod +x /usr/local/bin/cloudflared
    log_success "Cloudflared 安装完成。"
}

configure_cloudflared_tunnel() {
    log_info "配置 Cloudflare Tunnel..."
    SANITIZED_DOMAIN=$(echo "$DOMAIN" | tr '.' '-')
    TUNNEL_NAME="sb-${SANITIZED_DOMAIN}-$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 4)"

    log_warning "Cloudflare Tunnel 需要授权。"
    log_warning "请复制接下来显示的 URL，在您的本地计算机浏览器中打开，并授权访问您的 Cloudflare 账户。"
    log_warning "授权完成后，此脚本会自动继续。"
    echo ""
    # The cloudflared tunnel login command will block until authentication is complete
    # on the browser, and then it should download cert.pem to $CLOUDFLARED_CRED_DIR/cert.pem
    if ! cloudflared tunnel login; then
        log_error "Cloudflare 登录失败。请检查错误信息。"
        log_error "确保您在本地浏览器中正确完成了授权步骤。"
        log_error "您可能需要手动检查 ${CLOUDFLARED_CRED_DIR}/cert.pem 是否存在。"
        exit 1
    fi

    log_success "Cloudflare 登录授权似乎已完成。"
    
    # Verify that cert.pem was downloaded to the server
    if [ ! -f "${CLOUDFLARED_CRED_DIR}/cert.pem" ]; then
        log_error "Cloudflare 授权证书 (cert.pem) 未在服务器的 ${CLOUDFLARED_CRED_DIR}/cert.pem 路径下找到。"
        log_error "请确认以下几点："
        log_error "1. 您已在本地浏览器中成功完成了授权步骤。"
        log_error "2. 服务器上的 'cloudflared tunnel login' 命令没有提前中断。"
        log_error "3. 服务器具有正常的网络连接以下载证书。"
        log_error "4. /root/.cloudflared 目录权限正确 (脚本尝试设置为 700)。"
        log_warning "您可以尝试手动将您本地下载的 cert.pem 文件上传到服务器的 ${CLOUDFLARED_CRED_DIR}/cert.pem 位置，然后重新运行此脚本的这一部分或完整脚本。"
        exit 1
    else
        log_success "Cloudflare 授权证书 (cert.pem) 已在服务器 ${CLOUDFLARED_CRED_DIR}/cert.pem 找到。"
    fi
    
    log_info "正在创建或查找 Tunnel: $TUNNEL_NAME"
    
    TUNNEL_INFO_OUTPUT_FILE=$(mktemp)
    # When creating a tunnel, cloudflared uses cert.pem and then saves a <TUNNEL_ID>.json credential specific to this tunnel
    cloudflared tunnel create "$TUNNEL_NAME" > "$TUNNEL_INFO_OUTPUT_FILE" 2>&1
    TUNNEL_CREATE_OUTPUT=$(cat "$TUNNEL_INFO_OUTPUT_FILE")
    
    TUNNEL_ID=$(echo "$TUNNEL_CREATE_OUTPUT" | grep -oP 'created tunnel\s+\S+\s+with id\s+\K[0-9a-fA-F-]+')

    if [ -z "$TUNNEL_ID" ]; then
        log_warning "无法从创建输出中直接获取 Tunnel ID，或 Tunnel '$TUNNEL_NAME' 可能已存在。尝试通过名称查找..."
        TUNNEL_ID=$(cloudflared tunnel list -o json | jq -r --arg name "$TUNNEL_NAME" '.[] | select(.name == $name) | .id' | head -n 1)
        if [ -z "$TUNNEL_ID" ]; then
            log_error "创建或查找 Tunnel '$TUNNEL_NAME' 失败。"
            log_error "Cloudflared 输出: \n$TUNNEL_CREATE_OUTPUT"
            rm -f "$TUNNEL_INFO_OUTPUT_FILE"
            exit 1
        else
            log_info "找到已存在的 Tunnel '$TUNNEL_NAME' 的 ID: $TUNNEL_ID"
        fi
    else
        log_success "Tunnel '$TUNNEL_NAME' (ID: $TUNNEL_ID) 创建成功。"
    fi
    rm -f "$TUNNEL_INFO_OUTPUT_FILE"

    # After tunnel creation, a <TUNNEL_ID>.json file should exist
    local tunnel_json_cred="${CLOUDFLARED_CRED_DIR}/${TUNNEL_ID}.json"
    if [ ! -f "$tunnel_json_cred" ]; then
        log_warning "Tunnel 特定凭证文件 '${tunnel_json_cred}' 未找到。"
        log_warning "这可能表明 Tunnel 创建过程中存在问题，或者 cloudflared 的行为有所变化。"
        log_warning "服务可能依赖于全局的 cert.pem，但这并非最佳实践。"
    else
        log_success "Tunnel 特定凭证文件 '${tunnel_json_cred}' 已找到。"
    fi
    
    log_info "正在为域名 $DOMAIN 创建 DNS CNAME 记录指向 Tunnel..."
    if ! cloudflared tunnel route dns "$TUNNEL_ID" "$DOMAIN"; then
        log_warning "为 $DOMAIN 创建 DNS 记录失败。这可能是因为记录已存在或权限问题。"
        log_warning "您可以稍后在 Cloudflare Dashboard 中手动为 $DOMAIN 创建 CNAME 记录指向 ${TUNNEL_ID}.cfargotunnel.com"
    else
        log_success "DNS 记录创建/验证成功。"
    fi

    mkdir -p /etc/cloudflared/ # Configuration for cloudflared service
    
    cat > /etc/cloudflared/config.yml <<EOF
# This config file is used by 'cloudflared tunnel run <TUNNEL_ID_OR_NAME>'
# The tunnel ID/name is specified on the command line.
# Ingress rules defined here will apply to that tunnel.
# Credentials will be picked up from the default location: ${CLOUDFLARED_CRED_DIR}/${TUNNEL_ID}.json or ${CLOUDFLARED_CRED_DIR}/cert.pem

ingress:
  - hostname: ${DOMAIN}
    service: http://127.0.0.1:${SINGBOX_PORT}
    originRequest:
      noTLSVerify: true
  - service: http_status:404 # Catch-all for other requests
EOF
    log_success "Cloudflared Tunnel 配置完成 (/etc/cloudflared/config.yml)。"
}

setup_systemd_services() {
    log_info "设置 systemd 服务..."

    cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
User=root
WorkingDirectory=/etc/sing-box
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/cloudflared.service <<EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target 

[Service]
TimeoutStartSec=0
Type=notify
# cloudflared will use credentials from $CLOUDFLARED_CRED_DIR ($TUNNEL_ID.json or cert.pem)
ExecStart=/usr/local/bin/cloudflared tunnel --no-autoupdate --config /etc/cloudflared/config.yml run ${TUNNEL_ID}
Restart=on-failure
RestartSec=5s
User=root 

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable sing-box cloudflared

    log_info "正在启动 sing-box 服务..."
    if systemctl restart sing-box; then log_success "sing-box 服务已启动。"; else log_error "sing-box 服务启动失败。 journalctl -u sing-box -e"; fi
    
    sleep 3 

    log_info "正在启动 Cloudflared 服务..."
    if systemctl restart cloudflared; then log_success "Cloudflared 服务已启动。"; else log_error "Cloudflared 服务启动失败。 journalctl -u cloudflared -e"; fi

    log_info "等待服务稳定..."
    sleep 7 

    if ! systemctl is-active --quiet sing-box; then log_warning "sing-box 服务当前不活跃。 journalctl -u sing-box -e"; fi
    if ! systemctl is-active --quiet cloudflared; then log_warning "Cloudflared 服务当前不活跃。 journalctl -u cloudflared -e"; fi
}

generate_client_configs() {
    log_info "生成客户端配置信息..."
    REMARK_TAG="VLESS-CF-$(echo $DOMAIN | cut -d'.' -f1)"
    ENCODED_WS_PATH=$(urlencode "${WS_PATH}")
    ENCODED_REMARK_TAG=$(urlencode "${REMARK_TAG}")
    VLESS_LINK="vless://${VLESS_UUID}@${DOMAIN}:443?encryption=none&security=tls&sni=${DOMAIN}&type=ws&host=${DOMAIN}&path=${ENCODED_WS_PATH}#${ENCODED_REMARK_TAG}"

    echo -e "--------------------------------------------------"
    echo -e "${GREEN}部署完成！以下是您的 VLESS 连接信息：${NC}"
    echo -e "--------------------------------------------------"
    echo -e "${YELLOW}域名 (Address):${NC} ${DOMAIN}"
    echo -e "${YELLOW}端口 (Port):${NC} 443"
    echo -e "${YELLOW}用户 ID (UUID):${NC} ${VLESS_UUID}"
    echo -e "${YELLOW}传输协议 (Network):${NC} ws (WebSocket)"
    echo -e "${YELLOW}WebSocket 路径 (Path):${NC} ${WS_PATH}"
    echo -e "${YELLOW}WebSocket Host (伪装域名):${NC} ${DOMAIN}"
    echo -e "${YELLOW}TLS/SSL:${NC} tls (由 Cloudflare 提供)"
    echo -e "${YELLOW}SNI (Server Name Indication):${NC} ${DOMAIN}"
    echo -e "--------------------------------------------------"
    echo -e "${GREEN}VLESS 链接:${NC}"
    echo -e "${VLESS_LINK}"
    echo -e "--------------------------------------------------"
    echo -e "${GREEN}QR Code:${NC}"
    qrencode -t ANSIUTF8 "${VLESS_LINK}"
    echo -e "--------------------------------------------------"
    echo -e "${BLUE}Sing-box 客户端配置片段 (JSON):${NC}"
    cat <<EOF
{
  "type": "vless",
  "tag": "${REMARK_TAG}",
  "server": "${DOMAIN}",
  "server_port": 443,
  "uuid": "${VLESS_UUID}",
  "tls": {
    "enabled": true,
    "server_name": "${DOMAIN}",
    "insecure": false 
  },
  "transport": {
    "type": "ws",
    "path": "${WS_PATH}",
    "headers": {
      "Host": "${DOMAIN}"
    }
  }
}
EOF
    echo -e "--------------------------------------------------"
}

urlencode() {
    local string="${1}"
    local strlen=${#string}
    local encoded=""
    local pos c o
    for (( pos=0 ; pos<strlen ; pos++ )); do
        c=${string:$pos:1}
        case "$c" in
            [-_.~a-zA-Z0-9/] ) o="${c}" ;;
            * ) printf -v o '%%%02x' "'$c"
        esac
        encoded+="${o}"
    done
    echo "${encoded}"
}

save_installation_details() {
    log_info "正在保存安装详情以便卸载..."
    STATE_FILE="/etc/sing-box/install_details.env"
    mkdir -p "$(dirname "$STATE_FILE")" 
    
    if [ -f "$STATE_FILE" ]; then
        mv "$STATE_FILE" "${STATE_FILE}.bak_$(date +%Y%m%d%H%M%S)"
        log_info "已备份旧的安装详情文件到: ${STATE_FILE}.bak_..."
    fi

    echo "# Sing-box VLESS Cloudflare Tunnel Installation Details" > "$STATE_FILE"
    echo "DOMAIN=\"${DOMAIN}\"" >> "$STATE_FILE"
    echo "VLESS_UUID=\"${VLESS_UUID}\"" >> "$STATE_FILE"
    echo "SINGBOX_PORT=\"${SINGBOX_PORT}\"" >> "$STATE_FILE"
    echo "WS_PATH=\"${WS_PATH}\"" >> "$STATE_FILE"
    echo "TUNNEL_ID=\"${TUNNEL_ID}\"" >> "$STATE_FILE"
    echo "TUNNEL_NAME=\"${TUNNEL_NAME}\"" >> "$STATE_FILE"
    echo "SINGBOX_SERVICE_FILE=\"/etc/systemd/system/sing-box.service\"" >> "$STATE_FILE"
    echo "CLOUDFLARED_SERVICE_FILE=\"/etc/systemd/system/cloudflared.service\"" >> "$STATE_FILE"
    echo "SINGBOX_CONFIG_DIR=\"/etc/sing-box\"" >> "$STATE_FILE"
    echo "CLOUDFLARED_CONFIG_DIR=\"/etc/cloudflared\"" >> "$STATE_FILE"
    echo "SINGBOX_EXECUTABLE=\"/usr/local/bin/sing-box\"" >> "$STATE_FILE"
    echo "CLOUDFLARED_EXECUTABLE=\"/usr/local/bin/cloudflared\"" >> "$STATE_FILE"
    echo "CLOUDFLARED_CRED_DIR=\"${CLOUDFLARED_CRED_DIR}\"" >> "$STATE_FILE" # Use variable
    chmod 600 "$STATE_FILE"
    log_success "安装详情已保存到: $STATE_FILE"
}

# --- Main Script ---
main() {
    check_root # This now also ensures $CLOUDFLARED_CRED_DIR exists
    validate_and_set_configs
    detect_arch
    install_dependencies
    install_singbox
    install_cloudflared
    configure_cloudflared_tunnel # Modified to verify server-side cert.pem
    setup_systemd_services
    generate_client_configs
    save_installation_details
    log_success "所有操作已完成！"
    log_info "如果 Cloudflared 服务无法连接，请检查 ${CLOUDFLARED_CRED_DIR} 中的凭证，并在 Cloudflare Dashboard 检查 Tunnel '${TUNNEL_NAME}' (ID: ${TUNNEL_ID}) 的状态。"
}

main
