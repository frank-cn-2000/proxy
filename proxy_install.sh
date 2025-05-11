#!/bin/bash

# VLESS + sing-box + Cloudflare Tunnel + Let's Encrypt (via Cloudflare)
# Fully compatible with Ubuntu 24.04 LTS
# Author: AI Assistant (Handles existing cert.pem, robust API calls, stderr logging)

# --- Configuration File ---
CONFIG_FILE_NAME="config.cfg"
# Determine script's own directory robustly
SCRIPT_DIR_REAL=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)
CONFIG_FILE="${SCRIPT_DIR_REAL}/${CONFIG_FILE_NAME}"


# --- Global Variables ---
VLESS_UUID=""
SINGBOX_PORT=""
WS_PATH=""
DOMAIN=""           # Loaded from YOUR_DOMAIN in config
ZONE_NAME=""        # Loaded from YOUR_ZONE_NAME in config
CF_API_TOKEN=""     # Loaded from config
TUNNEL_ID=""
TUNNEL_NAME=""
CLOUDFLARED_CRED_DIR="/root/.cloudflared"
CLOUDFLARE_API_ENDPOINT="https://api.cloudflare.com/client/v4"

# --- Colors ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# --- Helper Functions (Log to stderr) ---
log_info() { echo -e "${BLUE}[INFO]${NC} $1" >&2; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1" >&2; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }


# --- Load Configuration ---
load_config() {
    if [[ "$CONFIG_FILE" == "/dev/fd/${CONFIG_FILE_NAME}" || "$CONFIG_FILE" == "/proc/self/fd/${CONFIG_FILE_NAME}" || "$SCRIPT_DIR_REAL" =~ ^/proc/[0-9]+/fd || -z "$SCRIPT_DIR_REAL" ]]; then
      CONFIG_FILE="$(pwd)/${CONFIG_FILE_NAME}"
      log_warning "脚本通过管道执行或无法确定脚本目录，尝试从当前工作目录加载配置文件: $CONFIG_FILE"
    fi

    if [ ! -f "$CONFIG_FILE" ]; then
        log_error "配置文件 '$CONFIG_FILE' 未找到。"
        log_error "请创建 '$CONFIG_FILE_NAME' (在脚本目录或当前工作目录) 并填入所需变量。"
        local template_creation_path="$(pwd)/${CONFIG_FILE_NAME}"
        echo -e "${YELLOW}正在当前工作目录创建模板配置文件: $template_creation_path${NC}" >&2
        cat > "$template_creation_path" <<EOF
# Cloudflare Deployment Configuration
YOUR_DOMAIN="your.example.com"
YOUR_ZONE_NAME="example.com" # Your actual Zone name in Cloudflare
CF_API_TOKEN="your_cloudflare_api_token_here"
EOF
        chmod 600 "$template_creation_path"
        log_info "模板文件已创建。请编辑它并重新运行脚本。" >&2
        exit 1
    fi

    log_info "正在从 '$CONFIG_FILE' 加载配置..."
    # Source the config file. Ensure it only contains variable assignments for security.
    # Consider more secure ways to read if config file content is not strictly controlled.
    source "$CONFIG_FILE"

    if [[ -z "$YOUR_DOMAIN" || "$YOUR_DOMAIN" == "your.example.com" ]]; then
        log_error "请在 '$CONFIG_FILE' 中设置有效的 'YOUR_DOMAIN'。"; exit 1
    fi
    if [[ -z "$YOUR_ZONE_NAME" || "$YOUR_ZONE_NAME" == "example.com" ]]; then
        log_error "请在 '$CONFIG_FILE' 中设置有效的 'YOUR_ZONE_NAME'。"; exit 1
    fi
    if [[ -z "$CF_API_TOKEN" || "$CF_API_TOKEN" == "your_cloudflare_api_token_here" ]]; then
        log_error "请在 '$CONFIG_FILE' 中设置有效的 'CF_API_TOKEN'。"; exit 1
    fi
    log_success "配置加载成功。"
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then log_error "此脚本需要 root 权限运行。"; exit 1; fi
    mkdir -p "$CLOUDFLARED_CRED_DIR"; chmod 700 "$CLOUDFLARED_CRED_DIR"
}

validate_and_set_configs() {
    DOMAIN="$YOUR_DOMAIN"
    ZONE_NAME="$YOUR_ZONE_NAME"
    log_info "将使用域名: $DOMAIN"
    log_info "将在 Zone: $ZONE_NAME 中操作 DNS"
    if ! [[ "$DOMAIN" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then log_error "域名 '$DOMAIN' 格式不正确。"; exit 1; fi
    if ! [[ "$ZONE_NAME" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then log_error "Zone 名称 '$ZONE_NAME' 格式不正确。"; exit 1; fi

    VLESS_UUID=$(uuidgen); log_info "VLESS UUID: $VLESS_UUID"
    SINGBOX_PORT=$(shuf -i 10000-65535 -n 1); log_info "Sing-box 本地端口: $SINGBOX_PORT"
    WS_PATH="/$(uuidgen | cut -d'-' -f1)-$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 8)"; log_info "WebSocket 路径: $WS_PATH"
}

detect_arch() {
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) ARCH_ALT="amd64" ;; aarch64) ARCH_ALT="arm64" ;; armv7l) ARCH_ALT="armv7" ;;
        *) log_error "不支持的系统架构: $ARCH"; exit 1 ;;
    esac; log_info "系统架构: $ARCH ($ARCH_ALT)"
}

install_dependencies() {
    log_info "安装依赖: curl, jq, unzip, uuid-runtime, qrencode..."
    apt update >/dev/null 2>&1
    if ! apt install -y curl jq unzip uuid-runtime qrencode >/dev/null 2>&1; then
        log_error "依赖安装失败。"; exit 1
    fi; log_success "依赖安装完成。"
}

# --- Cloudflare API Functions ---
cf_api_call() {
    local method="$1" path="$2" data="$3"
    local response_body http_code temp_file
    temp_file=$(mktemp)

    # Trim leading/trailing whitespace from API Token, just in case
    local trimmed_cf_api_token=$(echo "$CF_API_TOKEN" | xargs)


    local curl_opts=(-s -w "%{http_code}" \
        -H "Authorization: Bearer ${trimmed_cf_api_token}" \
        -H "Content-Type: application/json" \
        -o "$temp_file")

    # log_info "DEBUG: CF_API_TOKEN used: Bearer ${trimmed_cf_api_token:0:5}...${trimmed_cf_api_token: -5}" # Debug token

    if [[ "$method" == "GET" || "$method" == "DELETE" ]]; then
        http_code=$(curl "${curl_opts[@]}" -X "$method" "${CLOUDFLARE_API_ENDPOINT}${path}")
    elif [[ "$method" == "POST" || "$method" == "PUT" ]]; then
        http_code=$(curl "${curl_opts[@]}" -X "$method" --data "$data" "${CLOUDFLARE_API_ENDPOINT}${path}")
    else
        log_error "不支持的 HTTP 方法: $method"; rm -f "$temp_file"; return 1
    fi

    response_body=$(cat "$temp_file")
    rm -f "$temp_file"

    if ! [[ "$http_code" =~ ^2[0-9]{2}$ ]]; then
        local errors
        if echo "$response_body" | jq -e . >/dev/null 2>&1; then
            errors=$(echo "$response_body" | jq -r '.errors | map(.message) | join(", ") // "未知API错误 (响应非JSON或无错误信息)"')
        else
            errors="API响应非JSON或为空 (HTTP $http_code)"
        fi
        log_error "Cloudflare API 调用失败 ($http_code $method $path): $errors"
        log_info "失败的API响应体 (部分): $(echo "$response_body" | head -c 200)" # Show partial body for debugging
        return 1
    fi
    echo "$response_body"
    return 0
}

get_zone_id() {
    log_info "为配置的 Zone Name '$ZONE_NAME' 获取 Zone ID..."
    local response=$(cf_api_call "GET" "/zones?name=${ZONE_NAME}&status=active&match=all") || return 1
    local zone_id=$(echo "$response" | jq -r '.result[] | select(.name == "'"$ZONE_NAME"'") | .id' | head -n1)

    if [[ -z "$zone_id" || "$zone_id" == "null" ]]; then
        log_error "未能找到 Zone Name '$ZONE_NAME' 的 Zone ID。"
        log_error "请确保 '$ZONE_NAME' 是您 Cloudflare 账户下的有效 Zone，并且 API Token 有权限访问。"
        log_error "API 响应 (jq解析前): $response"
        return 1
    fi
    log_success "获取到 Zone ID: $zone_id for Zone Name: $ZONE_NAME"
    echo "$zone_id"
    return 0
}
# --- End Cloudflare API Functions ---

install_singbox() {
    log_info "正在安装 sing-box..."
    local SINGBOX_LATEST_URL="https://api.github.com/repos/SagerNet/sing-box/releases/latest"
    local SINGBOX_VERSION_TAG=$(curl -sL "$SINGBOX_LATEST_URL" | jq -r ".tag_name")
    local SINGBOX_VERSION
    if [ -z "$SINGBOX_VERSION_TAG" ] || [ "$SINGBOX_VERSION_TAG" == "null" ]; then
        SINGBOX_VERSION="1.9.0"; SINGBOX_VERSION_TAG="v${SINGBOX_VERSION}"; log_warning "无法获取最新 sing-box 版本, 使用 $SINGBOX_VERSION"
    else SINGBOX_VERSION=$(echo "$SINGBOX_VERSION_TAG" | sed 's/v//'); fi
    log_info "sing-box 版本: $SINGBOX_VERSION (标签: $SINGBOX_VERSION_TAG)"
    local DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/${SINGBOX_VERSION_TAG}/sing-box-${SINGBOX_VERSION}-linux-${ARCH_ALT}.tar.gz"
    log_info "下载 sing-box: $DOWNLOAD_URL"
    curl -Lo sing-box.tar.gz "$DOWNLOAD_URL" || { log_error "sing-box 下载失败。"; exit 1; }
    if ! tar -tzf sing-box.tar.gz > /dev/null 2>&1; then log_error "下载的 sing-box 文件无效。"; rm -f sing-box.tar.gz; exit 1; fi
    local ACTUAL_EXTRACT_DIR=$(tar -tzf sing-box.tar.gz | head -n1 | cut -f1 -d"/")
    tar -xzf sing-box.tar.gz || { log_error "解压 sing-box 失败。"; exit 1; }
    if [ ! -f "${ACTUAL_EXTRACT_DIR}/sing-box" ]; then log_error "未找到 sing-box 可执行文件。"; exit 1; fi
    mv "${ACTUAL_EXTRACT_DIR}/sing-box" /usr/local/bin/; chmod +x /usr/local/bin/sing-box
    rm -rf sing-box.tar.gz "${ACTUAL_EXTRACT_DIR}/"; mkdir -p /etc/sing-box/
    cat > /etc/sing-box/config.json <<EOF
{"log":{"level":"info","timestamp":true},"inbounds":[{"type":"vless","tag":"vless-in","listen":"127.0.0.1","listen_port":${SINGBOX_PORT},"users":[{"uuid":"${VLESS_UUID}","flow":""}],"transport":{"type":"ws","path":"${WS_PATH}","max_early_data":0,"early_data_header_name":"Sec-WebSocket-Protocol"}}],"outbounds":[{"type":"direct","tag":"direct"}]}
EOF
    log_success "sing-box 安装和配置完成。"
}

install_cloudflared() {
    log_info "正在安装 Cloudflared..."
    local CLOUDFLARED_LATEST_URL="https://api.github.com/repos/cloudflare/cloudflared/releases/latest"
    local CLOUDFLARED_VERSION_TAG=$(curl -sL "$CLOUDFLARED_LATEST_URL" | jq -r '.tag_name')
    local DOWNLOAD_URL
    if [ -z "$CLOUDFLARED_VERSION_TAG" ] || [ "$CLOUDFLARED_VERSION_TAG" == "null" ]; then
        DOWNLOAD_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH_ALT}"; log_warning "无法获取最新 Cloudflared 版本, 使用通用链接。"
    else DOWNLOAD_URL="https://github.com/cloudflare/cloudflared/releases/download/${CLOUDFLARED_VERSION_TAG}/cloudflared-linux-${ARCH_ALT}"; log_info "Cloudflared 版本标签: $CLOUDFLARED_VERSION_TAG"; fi
    curl -Lo /usr/local/bin/cloudflared "$DOWNLOAD_URL" || { log_error "Cloudflared 下载失败。"; exit 1; }
    chmod +x /usr/local/bin/cloudflared; log_success "Cloudflared 安装完成。"
}

configure_cloudflared_tunnel() {
    log_info "配置 Cloudflare Tunnel..."
    local SANITIZED_DOMAIN=$(echo "$DOMAIN" | tr '.' '-'); TUNNEL_NAME="sb-${SANITIZED_DOMAIN}-$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 4)"

    if [ -f "${CLOUDFLARED_CRED_DIR}/cert.pem" ]; then
        log_warning "检测到现有的 Cloudflare 授权证书: ${CLOUDFLARED_CRED_DIR}/cert.pem"
        local backup_cert="${CLOUDFLARED_CRED_DIR}/cert.pem.bak_$(date +%Y%m%d%H%M%S)"
        mv "${CLOUDFLARED_CRED_DIR}/cert.pem" "$backup_cert"
        log_info "已将现有证书备份到: $backup_cert"
        log_info "现在将继续进行新的登录授权流程。"
    fi

    log_warning "Cloudflare Tunnel 需要授权. 请复制显示的 URL 到本地浏览器并授权."
    # cloudflared tunnel login outputs its own messages.
    if ! cloudflared tunnel login; then
        # Check again if cert.pem was created despite non-zero exit (unlikely for fatal errors)
        if [ ! -f "${CLOUDFLARED_CRED_DIR}/cert.pem" ]; then
            log_error "Cloudflare 登录命令失败，并且未找到新的 cert.pem。"
            exit 1
        else
            log_warning "Cloudflare 登录命令返回了错误，但 cert.pem 文件存在。谨慎继续..."
        fi
    fi

    if [ ! -f "${CLOUDFLARED_CRED_DIR}/cert.pem" ]; then
        log_error "Cloudflare 登录授权未成功下载新的 cert.pem 到 ${CLOUDFLARED_CRED_DIR}。"
        log_error "请检查 cloudflared tunnel login 的输出，并确保您在浏览器中完成了授权。"
        exit 1
    fi
    log_success "Cloudflare 登录授权已完成，并已验证 cert.pem。"

    log_info "创建或查找 Tunnel: $TUNNEL_NAME"
    local TUNNEL_CREATE_OUTPUT=$(cloudflared tunnel create "$TUNNEL_NAME" 2>&1)
    TUNNEL_ID=$(echo "$TUNNEL_CREATE_OUTPUT" | grep -oP 'created tunnel\s+\S+\s+with id\s+\K[0-9a-fA-F-]+')
    if [ -z "$TUNNEL_ID" ]; then
        TUNNEL_ID=$(cloudflared tunnel list -o json | jq -r --arg name "$TUNNEL_NAME" '.[] | select(.name == $name) | .id' | head -n 1)
        if [ -z "$TUNNEL_ID" ]; then log_error "创建或查找 Tunnel '$TUNNEL_NAME' 失败.\n$TUNNEL_CREATE_OUTPUT"; exit 1; fi
        log_info "找到已存在的 Tunnel '$TUNNEL_NAME' ID: $TUNNEL_ID"
    else log_success "Tunnel '$TUNNEL_NAME' (ID: $TUNNEL_ID) 创建成功."; fi

    if [ ! -f "${CLOUDFLARED_CRED_DIR}/${TUNNEL_ID}.json" ]; then
         log_warning "Tunnel 特定凭证 ${TUNNEL_ID}.json 未找到. 服务可能依赖全局 cert.pem."
    else
         log_success "找到 Tunnel 特定凭证 ${TUNNEL_ID}.json."
    fi


    log_info "通过 API 管理 '$DOMAIN' 的 CNAME 记录..."
    local CF_ZONE_ID=$(get_zone_id) || { log_error "无法获取 Zone ID, 因此无法继续管理DNS. 请检查Cloudflare配置和API Token权限."; exit 1; }
    local tunnel_cname_target="${TUNNEL_ID}.cfargotunnel.com"
    log_info "Tunnel CNAME 目标: $tunnel_cname_target"
    local existing_records_response=$(cf_api_call "GET" "/zones/${CF_ZONE_ID}/dns_records?type=CNAME&name=${DOMAIN}")
    if [ $? -ne 0 ]; then
        log_warning "查询现有 DNS 记录失败. 尝试使用 'cloudflared tunnel route dns'..."
        if ! cloudflared tunnel route dns "$TUNNEL_ID" "$DOMAIN"; then
             log_error "'cloudflared tunnel route dns' 也失败了. 请手动在 Cloudflare Dashboard 中为 ${DOMAIN} 创建 CNAME (代理状态开启) 指向 ${tunnel_cname_target}"
        else
             log_success "'cloudflared tunnel route dns' 执行成功 (请在Dashboard确认代理状态开启)."
        fi
    else
        local record_id=$(echo "$existing_records_response" | jq -r '.result[] | select(.name == "'"$DOMAIN"'") | .id' | head -n 1)
        local current_content=$(echo "$existing_records_response" | jq -r '.result[] | select(.name == "'"$DOMAIN"'") | .content' | head -n 1)
        local current_proxied_status=$(echo "$existing_records_response" | jq -r '.result[] | select(.name == "'"$DOMAIN"'") | .proxied' | head -n 1)

        if [[ -n "$record_id" && "$record_id" != "null" ]]; then
            if [[ "$current_content" == "$tunnel_cname_target" && "$current_proxied_status" == "true" ]]; then
                log_success "CNAME 记录已是最新且代理状态正确."
            else
                log_info "CNAME 记录需要更新 (ID: $record_id, 当前内容: $current_content, 当前代理: $current_proxied_status)..."
                local update_data=$(jq -n --arg type "CNAME" --arg name "$DOMAIN" --arg content "$tunnel_cname_target" --argjson proxied true --argjson ttl 1 \
                '{type: $type, name: $name, content: $content, proxied: $proxied, ttl: $ttl}')
                local update_response=$(cf_api_call "PUT" "/zones/${CF_ZONE_ID}/dns_records/${record_id}" "$update_data")
                if [ $? -eq 0 ] && echo "$update_response" | jq -e '.success == true' > /dev/null; then
                    log_success "CNAME 更新成功 (代理状态已开启)."
                else
                    log_error "CNAME 更新失败."
                fi
            fi
        else
            log_info "创建新的 CNAME 记录 (代理状态开启)..."
            local create_data=$(jq -n --arg type "CNAME" --arg name "$DOMAIN" --arg content "$tunnel_cname_target" --argjson proxied true --argjson ttl 1 \
            '{type: $type, name: $name, content: $content, proxied: $proxied, ttl: $ttl}')
            local create_response=$(cf_api_call "POST" "/zones/${CF_ZONE_ID}/dns_records" "$create_data")
            if [ $? -eq 0 ] && echo "$create_response" | jq -e '.success == true' > /dev/null; then
                log_success "CNAME 创建成功 (代理状态已开启)."
            else
                log_error "CNAME 创建失败."
            fi
        fi
    fi
    mkdir -p /etc/cloudflared/; cat > /etc/cloudflared/config.yml <<EOF
ingress:
  - hostname: ${DOMAIN}
    service: http://127.0.0.1:${SINGBOX_PORT}
    originRequest: {noTLSVerify: true}
  - service: http_status:404
EOF
    log_success "Cloudflared Tunnel 配置完成 (/etc/cloudflared/config.yml)."
    log_warning "请验证 Cloudflare DNS 中的 CNAME 记录 (${DOMAIN}) 是否正确指向: ${tunnel_cname_target} 并且代理状态已开启 (橙色云彩)."
}

setup_systemd_services() {
    log_info "设置 systemd 服务..."
    cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
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
ExecStart=/usr/local/bin/cloudflared tunnel --no-autoupdate --config /etc/cloudflared/config.yml run ${TUNNEL_ID}
Restart=on-failure
RestartSec=5s
User=root

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload; systemctl enable sing-box cloudflared
    log_info "启动服务...";
    if systemctl restart sing-box; then log_success "sing-box 服务已启动."; else log_error "sing-box 启动失败. 查看: systemctl status sing-box.service 和 journalctl -u sing-box.service -e"; fi
    sleep 3;
    if systemctl restart cloudflared; then log_success "cloudflared 服务已启动."; else log_error "cloudflared 启动失败. 查看: systemctl status cloudflared.service 和 journalctl -u cloudflared.service -e"; fi
    sleep 7;
    if ! systemctl is-active --quiet sing-box; then log_warning "sing-box 服务当前不活跃."; fi
    if ! systemctl is-active --quiet cloudflared; then log_warning "cloudflared 服务当前不活跃."; fi
}

generate_client_configs() {
    local REMARK_TAG="VLESS-CF-$(echo $DOMAIN | cut -d'.' -f1)"
    local ENCODED_WS_PATH=$(urlencode "${WS_PATH}"); local ENCODED_REMARK_TAG=$(urlencode "${REMARK_TAG}")
    local VLESS_LINK="vless://${VLESS_UUID}@${DOMAIN}:443?encryption=none&security=tls&sni=${DOMAIN}&type=ws&host=${DOMAIN}&path=${ENCODED_WS_PATH}#${ENCODED_REMARK_TAG}"
    echo -e "---------------- VLESS 配置 ----------------"
    echo -e "${YELLOW}域名:${NC} ${DOMAIN}\n${YELLOW}端口:${NC} 443\n${YELLOW}UUID:${NC} ${VLESS_UUID}\n${YELLOW}路径:${NC} ${WS_PATH}\n${YELLOW}Host:${NC} ${DOMAIN}"
    echo -e "${GREEN}VLESS 链接:${NC}\n${VLESS_LINK}"
    echo -e "${GREEN}QR Code:${NC}"; qrencode -t ANSIUTF8 "${VLESS_LINK}"
    echo -e "${BLUE}Sing-box JSON 片段:${NC}"
    jq -n --arg tag "$REMARK_TAG" --arg server "$DOMAIN" --argjson port 443 --arg uuid "$VLESS_UUID" \
          --arg sni "$DOMAIN" --arg path "$WS_PATH" --arg host "$DOMAIN" \
    '{type:"vless",tag:$tag,server:$server,server_port:$port,uuid:$uuid,tls:{enabled:true,server_name:$sni,insecure:false},transport:{type:"ws",path:$path,headers:{Host:$host}}}'
    echo -e "--------------------------------------------"
}

urlencode() {
    local string="${1}" encoded="" pos c o; local strlen=${#string}
    for (( pos=0 ; pos<strlen ; pos++ )); do c=${string:$pos:1}
        case "$c" in [-_.a-zA-Z0-9/] ) o="${c}" ;; * ) printf -v o '%%%02x' "'$c"; esac
        encoded+="${o}"; done; echo "${encoded}"
}

save_installation_details() {
    log_info "保存安装详情..."
    local STATE_FILE="/etc/sing-box/install_details.env"; mkdir -p "$(dirname "$STATE_FILE")"
    if [ -f "$STATE_FILE" ]; then mv "$STATE_FILE" "${STATE_FILE}.bak_$(date +%Y%m%d%H%M%S)"; fi

    printf "%s\n" "# Sing-box VLESS Cloudflare Tunnel Installation Details" > "$STATE_FILE"
    printf "DOMAIN=\"%s\"\n" "${DOMAIN}" >> "$STATE_FILE"
    printf "ZONE_NAME=\"%s\"\n" "${ZONE_NAME}" >> "$STATE_FILE"
    printf "VLESS_UUID=\"%s\"\n" "${VLESS_UUID}" >> "$STATE_FILE"
    printf "SINGBOX_PORT=\"%s\"\n" "${SINGBOX_PORT}" >> "$STATE_FILE"
    printf "WS_PATH=\"%s\"\n" "${WS_PATH}" >> "$STATE_FILE"
    printf "TUNNEL_ID=\"%s\"\n" "${TUNNEL_ID}" >> "$STATE_FILE"
    printf "TUNNEL_NAME=\"%s\"\n" "${TUNNEL_NAME}" >> "$STATE_FILE"
    printf "SINGBOX_SERVICE_FILE=\"%s\"\n" "/etc/systemd/system/sing-box.service" >> "$STATE_FILE"
    printf "CLOUDFLARED_SERVICE_FILE=\"%s\"\n" "/etc/systemd/system/cloudflared.service" >> "$STATE_FILE"
    printf "SINGBOX_CONFIG_DIR=\"%s\"\n" "/etc/sing-box" >> "$STATE_FILE"
    printf "CLOUDFLARED_CONFIG_DIR=\"%s\"\n" "/etc/cloudflared" >> "$STATE_FILE"
    printf "SINGBOX_EXECUTABLE=\"%s\"\n" "/usr/local/bin/sing-box" >> "$STATE_FILE"
    printf "CLOUDFLARED_EXECUTABLE=\"%s\"\n" "/usr/local/bin/cloudflared" >> "$STATE_FILE"
    printf "CLOUDFLARED_CRED_DIR=\"%s\"\n" "${CLOUDFLARED_CRED_DIR}" >> "$STATE_FILE"

    chmod 600 "$STATE_FILE"
    log_success "安装详情已保存到: $STATE_FILE"
}

# --- Main Script ---
main() {
    load_config
    check_root
    validate_and_set_configs
    detect_arch
    install_dependencies
    install_singbox
    install_cloudflared
    configure_cloudflared_tunnel
    setup_systemd_services
    generate_client_configs
    save_installation_details
    log_success "所有操作已完成！"
    log_info "检查 ${CLOUDFLARED_CRED_DIR} 凭证和 Cloudflare Dashboard Tunnel '${TUNNEL_NAME}' (ID: ${TUNNEL_ID}) 状态。"
}

# set -e # Uncomment for stricter error checking if desired

main "$@"
