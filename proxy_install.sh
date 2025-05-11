#!/bin/bash

# VLESS + sing-box + Cloudflare Tunnel + Let's Encrypt (via Cloudflare)
# Fully compatible with Ubuntu 24.04 LTS
# Author: AI Assistant (Modified for direct script configuration, random internal params)

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
}

validate_and_set_configs() {
    log_info "正在验证和设置配置..."
    if [[ -z "$YOUR_DOMAIN" || "$YOUR_DOMAIN" == "your.domain.com" || "$YOUR_DOMAIN" == *"YOUR_DOMAIN"* ]]; then
        log_error "请编辑脚本文件，将顶部的 'YOUR_DOMAIN' 变量设置为您自己的域名。"
        exit 1
    fi
    DOMAIN="$YOUR_DOMAIN"

    # Basic validation for domain format
    if ! [[ "$DOMAIN" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        log_error "配置的域名 '$DOMAIN' 格式不正确。"
        exit 1
    fi
    log_info "将使用域名: $DOMAIN"

    # Generate VLESS UUID
    VLESS_UUID=$(uuidgen)
    log_info "随机生成的 VLESS UUID: $VLESS_UUID"

    # Generate sing-box local port
    SINGBOX_PORT=$(shuf -i 10000-65535 -n 1)
    log_info "随机生成的 sing-box 本地端口: $SINGBOX_PORT"

    # Generate WebSocket path
    WS_PATH="/$(uuidgen | cut -d'-' -f1)-$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 8)" # e.g., /xxxx-AbCdEfGh
    log_info "随机生成的 WebSocket 路径: $WS_PATH"
}


detect_arch() {
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) ARCH_ALT="amd64" ;;
        aarch64) ARCH_ALT="arm64" ;;
        armv7l) ARCH_ALT="armv7" ;; # Note: sing-box might not have armv7 precompiled for latest versions
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
        log_warning "使用备用版本号: $SINGBOX_VERSION"
    else
        SINGBOX_VERSION=$(echo "$SINGBOX_VERSION_TAG" | sed 's/v//')
        log_info "获取到最新 sing-box 版本: $SINGBOX_VERSION (Tag: $SINGBOX_VERSION_TAG)"
    fi

    DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/${SINGBOX_VERSION_TAG}/sing-box-${SINGBOX_VERSION}-linux-${ARCH_ALT}.tar.gz"
    
    log_info "正在从 $DOWNLOAD_URL 下载 sing-box..."
    curl -Lo sing-box.tar.gz "$DOWNLOAD_URL"
    if [ $? -ne 0 ]; then
        log_error "sing-box 下载失败。"
        # Try an alternative download link if available for specific arch like armv7
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

    # Check if downloaded file is a valid tar.gz
    if ! tar -tzf sing-box.tar.gz > /dev/null 2>&1; then
        log_error "下载的 sing-box 文件不是有效的 tar.gz 压缩包。可能是下载链接有误或架构不支持。"
        rm -f sing-box.tar.gz
        exit 1
    fi

    TARGET_DIR="sing-box-${SINGBOX_VERSION}-linux-${ARCH_ALT}"
    # Handle potential hf suffix for armv7
    if [ "$ARCH_ALT" == "armv7" ] && ! tar -tzf sing-box.tar.gz | grep -q "${TARGET_DIR}/sing-box"; then
        TARGET_DIR="sing-box-${SINGBOX_VERSION}-linux-${ARCH_ALT}hf"
    fi
    
    tar -xzf sing-box.tar.gz
    if [ ! -f "${TARGET_DIR}/sing-box" ]; then
        log_error "解压后未找到 sing-box 可执行文件。目录结构可能已更改。"
        ls -lah # list files for debugging
        rm -rf sing-box.tar.gz "${TARGET_DIR}"
        exit 1
    fi

    mv "${TARGET_DIR}/sing-box" /usr/local/bin/
    chmod +x /usr/local/bin/sing-box
    rm -rf sing-box.tar.gz "${TARGET_DIR}/"

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
    # Sanitize domain for tunnel name (replace dots with hyphens) and add a short random suffix
    SANITIZED_DOMAIN=$(echo "$DOMAIN" | tr '.' '-')
    TUNNEL_NAME="sb-${SANITIZED_DOMAIN}-$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 4)"

    log_warning "接下来您需要登录您的 Cloudflare 账户。"
    log_warning "请复制以下链接并在浏览器中打开进行授权。"
    cloudflared tunnel login

    # Check if login was successful by listing tunnels
    if ! cloudflared tunnel list > /dev/null 2>&1; then
       log_warning "Cloudflare 登录可能未完成或检测失败。脚本将继续，但如果后续步骤失败，请手动执行 'cloudflared tunnel login' 并重新运行部分配置。"
    fi
    
    log_info "已登录 (或假定已登录)。正在创建或查找 Tunnel: $TUNNEL_NAME"
    
    # Attempt to create the tunnel. If it already exists, cloudflared might error or inform.
    # We'll try to get its ID anyway.
    TUNNEL_INFO_OUTPUT_FILE=$(mktemp)
    cloudflared tunnel create "$TUNNEL_NAME" > "$TUNNEL_INFO_OUTPUT_FILE" 2>&1
    TUNNEL_CREATE_OUTPUT=$(cat "$TUNNEL_INFO_OUTPUT_FILE")
    
    # Try to parse ID from create output
    TUNNEL_ID=$(echo "$TUNNEL_CREATE_OUTPUT" | grep -oP 'created tunnel\s+\S+\s+with id\s+\K[0-9a-fA-F-]+')

    if [ -z "$TUNNEL_ID" ]; then
        # If ID not found in create output, or create failed because it exists, list and find by name
        log_warning "无法从创建输出中直接获取 Tunnel ID，或 Tunnel '$TUNNEL_NAME' 可能已存在。尝试通过名称查找..."
        TUNNEL_ID=$(cloudflared tunnel list -o json | jq -r --arg name "$TUNNEL_NAME" '.[] | select(.name == $name) | .id' | head -n 1)
        if [ -z "$TUNNEL_ID" ]; then
            log_error "创建或查找 Tunnel '$TUNNEL_NAME' 失败。"
            log_error "Cloudflared 输出: \n$TUNNEL_CREATE_OUTPUT"
            log_error "请检查您的 Cloudflare 账户和权限，或手动创建 Tunnel。"
            rm -f "$TUNNEL_INFO_OUTPUT_FILE"
            exit 1
        else
            log_info "找到已存在的 Tunnel '$TUNNEL_NAME' 的 ID: $TUNNEL_ID"
        fi
    else
        log_success "Tunnel '$TUNNEL_NAME' (ID: $TUNNEL_ID) 创建成功。"
    fi
    rm -f "$TUNNEL_INFO_OUTPUT_FILE"
    
    log_info "正在为域名 $DOMAIN 创建 DNS CNAME 记录指向 Tunnel..."
    if ! cloudflared tunnel route dns "$TUNNEL_ID" "$DOMAIN"; then
        log_warning "为 $DOMAIN 创建 DNS 记录失败。这可能是因为记录已存在或权限问题。"
        log_warning "您可以稍后在 Cloudflare Dashboard 中手动为 $DOMAIN 创建 CNAME 记录指向 ${TUNNEL_ID}.cfargotunnel.com"
    else
        log_success "DNS 记录创建/验证成功。"
    fi

    mkdir -p /etc/cloudflared/
    CREDENTIALS_FILE_PATH="/root/.cloudflared/${TUNNEL_ID}.json" 
    DEFAULT_CRED_FILE="/root/.cloudflared/cert.pem"

    if [ ! -f "$CREDENTIALS_FILE_PATH" ] && [ ! -f "$DEFAULT_CRED_FILE" ]; then
        log_error "Cloudflare Tunnel 凭证文件 ('${TUNNEL_ID}.json' 或 'cert.pem') 在 /root/.cloudflared/ 中未找到。"
        log_error "这通常在 'cloudflared tunnel login' 之后生成。请确保登录成功。"
        log_warning "Tunnel 服务可能无法启动。脚本将继续，但请检查此问题。"
        # We will use TUNNEL_ID.json in config, cloudflared might still work if cert.pem is used globally for the account
    fi

    cat > /etc/cloudflared/config.yml <<EOF
# tunnel: ${TUNNEL_ID} # Not needed if running 'cloudflared tunnel run <TUNNEL_ID_OR_NAME>'
# credentials-file: ${CREDENTIALS_FILE_PATH} # Default location is usually fine

# The primary way to run the tunnel:
# cloudflared tunnel --config /etc/cloudflared/config.yml run ${TUNNEL_ID}
# Or, if the tunnel ID is specified in this config.yml:
# cloudflared tunnel --config /etc/cloudflared/config.yml run
# The service file will use 'cloudflared tunnel run ${TUNNEL_ID}'

# Configuration for the tunnel when run with 'cloudflared tunnel run <TUNNEL_ID_OR_NAME>'
# or when 'tunnel: <ID>' is specified above.
# This ingress section will be used by the named tunnel.

url: http://127.0.0.1:${SINGBOX_PORT}
# The following is an alternative way if you prefer to specify tunnel ID within the config file
# tunnel: ${TUNNEL_ID}
# credentials-file: ${CREDENTIALS_FILE_PATH}
# ingress:
#   - hostname: ${DOMAIN}
#     service: http://127.0.0.1:${SINGBOX_PORT}
#     originRequest:
#       noTLSVerify: true
#   - service: http_status:404
EOF
# Simpler config.yml:
# The tunnel ID will be passed as an argument to `cloudflared tunnel run`.
# The `ingress` rules in the config file are implicitly applied to the tunnel run this way
# if no `tunnel:` key is present OR if rules are defined under a specific tunnel ID.
# Let's use a more explicit config that works well when `cloudflared tunnel run <TUNNEL_ID>` is used.

    cat > /etc/cloudflared/config.yml <<EOF
# This config file is used by 'cloudflared tunnel run <TUNNEL_ID_OR_NAME>'
# The tunnel ID/name is specified on the command line.
# Ingress rules defined here will apply to that tunnel.

# If you want to run 'cloudflared tunnel run' without arguments, uncomment these:
# tunnel: ${TUNNEL_ID}
# credentials-file: /root/.cloudflared/${TUNNEL_ID}.json

ingress:
  - hostname: ${DOMAIN}
    service: http://127.0.0.1:${SINGBOX_PORT}
    originRequest:
      noTLSVerify: true
      # httpHostHeader: ${DOMAIN} # Usually not needed with WS path routing
  - service: http_status:404 # Catch-all for other requests
EOF

    log_success "Cloudflared Tunnel 配置完成 (/etc/cloudflared/config.yml)。"
}

setup_systemd_services() {
    log_info "设置 systemd 服务..."

    # sing-box service
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

    # cloudflared service
    # We will run cloudflared specifying the tunnel ID directly.
    # The config.yml will provide the ingress rules.
    cat > /etc/systemd/system/cloudflared.service <<EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target 

[Service]
TimeoutStartSec=0
Type=notify
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
    if systemctl restart sing-box; then
        log_success "sing-box 服务已启动。"
    else
        log_error "sing-box 服务启动失败。请检查日志: journalctl -u sing-box -e"
    fi
    
    sleep 3 

    log_info "正在启动 Cloudflared 服务..."
    if systemctl restart cloudflared; then
        log_success "Cloudflared 服务已启动。"
    else
        log_error "Cloudflared 服务启动失败。请检查日志: journalctl -u cloudflared -e"
    fi

    log_info "等待服务稳定..."
    sleep 7 

    if ! systemctl is-active --quiet sing-box; then
        log_warning "sing-box 服务当前不活跃。请检查日志: journalctl -u sing-box -e"
    fi
    if ! systemctl is-active --quiet cloudflared; then
        log_warning "Cloudflared 服务当前不活跃。请检查日志: journalctl -u cloudflared -e"
    fi
}

generate_client_configs() {
    log_info "生成客户端配置信息..."
    REMARK_TAG="VLESS-CF-$(echo $DOMAIN | cut -d'.' -f1)"
    # URL encode path and remark for VLESS link
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
    echo -e "${YELLOW}跳过证书验证 (allowInsecure):${NC} false (Cloudflare证书是受信任的)"
    echo -e "--------------------------------------------------"
    echo -e "${GREEN}VLESS 链接:${NC}"
    echo -e "${VLESS_LINK}"
    echo -e "--------------------------------------------------"
    echo -e "${GREEN}QR Code (请使用支持VLESS链接的客户端扫描):${NC}"
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
    "server_name": "${DOMAIN}", // SNI
    "insecure": false 
  },
  "transport": {
    "type": "ws",
    "path": "${WS_PATH}",
    "headers": {
      "Host": "${DOMAIN}" // WebSocket Host
    }
  }
}
EOF
    echo -e "--------------------------------------------------"
    log_info "如果 Cloudflared 服务无法连接到 Tunnel，请检查 '/root/.cloudflared/' 目录下的凭证文件。"
    log_info "您可能需要在 Cloudflare Dashboard (Zero Trust -> Access -> Tunnels) 中检查 Tunnel '${TUNNEL_NAME}' (ID: ${TUNNEL_ID}) 的状态和 DNS 设置。"
}

# URL Encode function for VLESS link generation
urlencode() {
    local string="${1}"
    local strlen=${#string}
    local encoded=""
    local pos c o

    for (( pos=0 ; pos<strlen ; pos++ )); do
        c=${string:$pos:1}
        case "$c" in
            [-_.~a-zA-Z0-9/] ) o="${c}" ;; # Forward slash is generally safe in path part of URL
            * ) printf -v o '%%%02x' "'$c"
        esac
        encoded+="${o}"
    done
    echo "${encoded}"
}


# --- Main Script ---
main() {
    check_root
    validate_and_set_configs
    detect_arch
    install_dependencies
    install_singbox
    install_cloudflared
    configure_cloudflared_tunnel # This sets TUNNEL_ID and TUNNEL_NAME
    setup_systemd_services
    generate_client_configs
    log_success "所有操作已完成！"
}

# Execute main function
main
