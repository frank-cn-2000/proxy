#!/bin/bash

# Uninstallation script for VLESS + sing-box + Cloudflare Tunnel
# Author: AI Assistant (Reads API token from config.cfg IF NEEDED, does not modify config.cfg)

# --- Configuration File for API Token (READ-ONLY for uninstall) ---
CONFIG_FILE_NAME="config.cfg"
# Determine script's own directory or PWD if piped
SCRIPT_DIR_REAL=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)
CONFIG_FILE="${SCRIPT_DIR_REAL}/${CONFIG_FILE_NAME}"


# --- State File (Primary source for uninstall info) ---
STATE_FILE="/etc/sing-box/install_details.env"

# --- Global Variables ---
CLOUDFLARE_API_ENDPOINT="https://api.cloudflare.com/client/v4"
# CF_API_TOKEN, DOMAIN, ZONE_NAME, TUNNEL_ID, etc., will be loaded

# --- Colors ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# --- Helper Functions (Log to stderr) ---
log_info() { echo -e "${BLUE}[INFO]${NC} $1" >&2; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1" >&2; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

check_root() { if [ "$(id -u)" -ne 0 ]; then log_error "此脚本需要 root 权限运行。"; exit 1; fi; }

# --- Load API Token (from config.cfg, read-only) ---
load_api_token_from_config() {
    if [ -n "$CF_API_TOKEN" ]; then return 0; fi # Already set (e.g., by user env)

    # Adjust CONFIG_FILE path if script is piped
    if [[ "$CONFIG_FILE" == "/dev/fd/${CONFIG_FILE_NAME}" || "$CONFIG_FILE" == "/proc/self/fd/${CONFIG_FILE_NAME}" || "$SCRIPT_DIR_REAL" =~ ^/proc/[0-9]+/fd || -z "$SCRIPT_DIR_REAL" ]]; then
      CONFIG_FILE="$(pwd)/${CONFIG_FILE_NAME}"
      log_warning "脚本通过管道执行或无法确定脚本目录，尝试从当前工作目录加载API Token配置文件: $CONFIG_FILE"
    fi

    if [ ! -f "$CONFIG_FILE" ]; then
        log_warning "配置文件 '$CONFIG_FILE' 未找到。如果需要通过 API 清理 DNS，请确保它存在并包含 CF_API_TOKEN。"
        return 1
    fi
    # Read only the CF_API_TOKEN line to avoid sourcing unwanted variables from config.cfg
    local token_val=$(grep -E "^CF_API_TOKEN\s*=" "$CONFIG_FILE" | head -n1 | cut -d'=' -f2- | sed 's/^[ \t"]*//;s/[ \t"]*$//')
    if [[ -n "$token_val" && "$token_val" != "your_cloudflare_api_token_here" ]]; then
        CF_API_TOKEN="$token_val"; log_info "从 '$CONFIG_FILE' (只读) 加载了 CF_API_TOKEN 用于 DNS 清理。"; return 0
    else
        log_warning "在 '$CONFIG_FILE' 中未找到或无效的 CF_API_TOKEN。将无法通过 API 清理 DNS。"; CF_API_TOKEN=""; return 1
    fi
}

# --- Load Installation Details (from state file) ---
load_install_details() {
    log_info "加载安装详情从: $STATE_FILE"
    if [ -f "$STATE_FILE" ]; then
        # Source the state file carefully, it should only contain variable assignments
        # Consider validating content or using grep/sed if concerned about arbitrary code
        source "$STATE_FILE"
        log_success "安装详情加载成功。"
        # Variables like DOMAIN, ZONE_NAME, TUNNEL_ID, etc. are now available
    else
        log_warning "安装详情文件 '$STATE_FILE' 未找到。"
        log_warning "将执行通用清理，但 Cloudflare 资源可能需要手动删除。"
        # Set defaults to allow some cleanup even if state file is missing
        SINGBOX_SERVICE_FILE="/etc/systemd/system/sing-box.service"
        CLOUDFLARED_SERVICE_FILE="/etc/systemd/system/cloudflared.service"
        SINGBOX_CONFIG_DIR="/etc/sing-box" # This also contains the state file normally
        CLOUDFLARED_CONFIG_DIR="/etc/cloudflared"
        SINGBOX_EXECUTABLE="/usr/local/bin/sing-box"
        CLOUDFLARED_EXECUTABLE="/usr/local/bin/cloudflared"
        CLOUDFLARED_CRED_DIR="/root/.cloudflared"
        DOMAIN="" ZONE_NAME="" TUNNEL_ID="" TUNNEL_NAME="" # Explicitly clear these if state is missing
    fi
}

# --- Cloudflare API Functions (Copied from install script, ensure they use loaded CF_API_TOKEN) ---
cf_api_call() {
    local method="$1" path="$2" data="$3"
    local response_body http_code temp_file
    temp_file=$(mktemp)
    local trimmed_cf_api_token=$(echo "$CF_API_TOKEN" | xargs) # Ensure token is clean
    local curl_opts=(-s -w "%{http_code}" \
        -H "Authorization: Bearer ${trimmed_cf_api_token}" \
        -H "Content-Type: application/json" \
        -o "$temp_file")
    if [[ "$method" == "GET" || "$method" == "DELETE" ]]; then
        http_code=$(curl "${curl_opts[@]}" -X "$method" "${CLOUDFLARE_API_ENDPOINT}${path}")
    elif [[ "$method" == "POST" || "$method" == "PUT" ]]; then
        http_code=$(curl "${curl_opts[@]}" -X "$method" --data "$data" "${CLOUDFLARE_API_ENDPOINT}${path}")
    else log_error "不支持的 HTTP 方法: $method"; rm -f "$temp_file"; return 1; fi
    response_body=$(cat "$temp_file"); rm -f "$temp_file"
    if ! [[ "$http_code" =~ ^2[0-9]{2}$ ]]; then
        local errors; if echo "$response_body" | jq -e . >/dev/null 2>&1; then
            errors=$(echo "$response_body" | jq -r '.errors | map(.message) | join(", ") // "未知API错误"')
        else errors="API响应非JSON或为空 (HTTP $http_code)"; fi
        log_error "Cloudflare API 调用失败 ($http_code $method $path): $errors"; return 1
    fi; echo "$response_body"; return 0
}
get_zone_id() {
    if [[ -z "$ZONE_NAME" ]]; then log_error "Zone Name 未知 (未从状态文件加载). 无法获取 Zone ID."; return 1; fi
    log_info "为 Zone Name '$ZONE_NAME' 获取 Zone ID..."
    local response=$(cf_api_call "GET" "/zones?name=${ZONE_NAME}&status=active&match=all") || return 1
    local zone_id=$(echo "$response" | jq -r '.result[] | select(.name == "'"$ZONE_NAME"'") | .id' | head -n1)
    if [[ -z "$zone_id" || "$zone_id" == "null" ]]; then
        log_error "未能找到 Zone Name '$ZONE_NAME' 的 Zone ID."; log_error "API 响应: $response"; return 1
    fi
    log_success "获取到 Zone ID: $zone_id for Zone Name: $ZONE_NAME"; echo "$zone_id"; return 0
}
# --- End Cloudflare API Functions ---

stop_and_disable_services() {
    log_info "停止并禁用服务..."
    for service in "sing-box" "cloudflared"; do
        if systemctl list-unit-files | grep -q "^${service}.service"; then
            systemctl stop "$service" >/dev/null 2>&1; systemctl disable "$service" >/dev/null 2>&1
            log_success "${service} 服务已停止并禁用."
        else log_warning "${service} 服务文件可能已被移除."; fi
    done; systemctl daemon-reload
}

remove_files_and_dirs() {
    log_info "删除相关文件和目录..."
    # Use variables from state file (or defaults if state file was missing)
    local _sbsvc=${SINGBOX_SERVICE_FILE:-/etc/systemd/system/sing-box.service}
    local _cfdsvc=${CLOUDFLARED_SERVICE_FILE:-/etc/systemd/system/cloudflared.service}
    local _sbexe=${SINGBOX_EXECUTABLE:-/usr/local/bin/sing-box}
    local _cfdexe=${CLOUDFLARED_EXECUTABLE:-/usr/local/bin/cloudflared}
    local _sbconfdir=${SINGBOX_CONFIG_DIR:-/etc/sing-box}
    local _cfdconfdir=${CLOUDFLARED_CONFIG_DIR:-/etc/cloudflared}
    local _cfdcreddir=${CLOUDFLARED_CRED_DIR:-/root/.cloudflared}

    for file_path in "$_sbsvc" "$_cfdsvc" "$_sbexe" "$_cfdexe"; do
        if [ -n "$file_path" ] && [ -f "$file_path" ]; then rm -f "$file_path"; log_success "删除: $file_path"; fi
    done
    # Important: _sbconfdir contains the STATE_FILE itself. This should be last among config dirs.
    for dir_path in "$_cfdconfdir" "$_sbconfdir"; do
        if [ -n "$dir_path" ] && [ -d "$dir_path" ]; then rm -rf "$dir_path"; log_success "删除目录: $dir_path"; fi
    done

    if [ -n "$TUNNEL_ID" ] && [ -f "${_cfdcreddir}/${TUNNEL_ID}.json" ]; then
        rm -f "${_cfdcreddir}/${TUNNEL_ID}.json"; log_success "删除特定 Tunnel 凭证: ${_cfdcreddir}/${TUNNEL_ID}.json"
    fi
    # We will NOT automatically delete the entire _cfdcreddir or cert.pem without explicit user action outside this script.
    if [ -d "$_cfdcreddir" ]; then
         log_warning "Cloudflare 凭证目录 '${_cfdcreddir}' 及其中的 'cert.pem' (账户级凭证) 未被此脚本自动删除。"
         log_warning "如果不再需要，请评估后手动删除。"
    fi
    systemctl daemon-reload
}

cleanup_cloudflare_dns_api() {
    log_info "通过 API 清理 '$DOMAIN' 的 Cloudflare DNS CNAME 记录..."
    if [[ -z "$DOMAIN" ]]; then log_warning "域名未知 (未从状态文件加载). 无法通过API清理 DNS."; return 1; fi
    if ! load_api_token_from_config; then return 1; fi # Try to load token if not already set
    if [[ -z "$CF_API_TOKEN" ]]; then log_warning "未提供或加载 CF_API_TOKEN. 无法通过 API 清理 DNS."; return 1; fi
    if [[ -z "$ZONE_NAME" ]]; then log_warning "Zone Name 未知 (未从状态文件加载). 无法通过 API 清理 DNS."; return 1; fi


    local CF_ZONE_ID=$(get_zone_id) || { return 1; } # Uses global ZONE_NAME loaded from state
    local existing_records_response=$(cf_api_call "GET" "/zones/${CF_ZONE_ID}/dns_records?type=CNAME&name=${DOMAIN}")
    if [ $? -ne 0 ]; then log_error "查询现有 DNS 记录失败 (用于删除)."; return 1; fi

    local record_id=$(echo "$existing_records_response" | jq -r '.result[] | select(.name == "'"$DOMAIN"'") | .id' | head -n 1)
    local current_content=$(echo "$existing_records_response" | jq -r '.result[] | select(.name == "'"$DOMAIN"'") | .content' | head -n 1)

    if [[ -n "$record_id" && "$record_id" != "null" ]]; then
        # Only delete if it looks like a tunnel record (points to .cfargotunnel.com)
        # And matches the TUNNEL_ID from state file if available (more safety)
        local expected_cname_part="${TUNNEL_ID}.cfargotunnel.com"
        if [[ "$current_content" == *".cfargotunnel.com"* ]] && { [[ -z "$TUNNEL_ID" ]] || [[ "$current_content" == "$expected_cname_part" ]]; }; then
            log_info "找到匹配的 CNAME (ID: $record_id, 内容: $current_content). 正在删除..."
            local delete_response=$(cf_api_call "DELETE" "/zones/${CF_ZONE_ID}/dns_records/${record_id}")
            if [ $? -eq 0 ] && echo "$delete_response" | jq -e '.success == true' > /dev/null; then
                 log_success "CNAME (ID: $record_id) 删除成功."
            else
                 log_error "CNAME 删除失败."
            fi
        else
             log_warning "找到 CNAME (ID: $record_id), 但其内容 ($current_content) 与预期的 Tunnel 记录 ($expected_cname_part) 不完全匹配或非 Tunnel 记录. 跳过 API 删除以策安全."
        fi
    else log_info "未找到 '$DOMAIN' 的 CNAME 记录, 无需通过 API 删除."; fi
}

list_dependencies() {
    log_info "此部署脚本可能已安装以下依赖项:"
    echo -e "${YELLOW}  curl, jq, unzip, uuid-runtime, qrencode${NC}" >&2 # Ensure this goes to stderr
    log_info "这些是通用工具，可能被系统上其他应用使用。"
    log_info "如果您确定不再需要它们，可以运行以下命令手动卸载:"
    echo -e "${YELLOW}  sudo apt autoremove --purge curl jq unzip uuid-runtime qrencode${NC}" >&2
    log_warning "请谨慎操作，确保不会影响其他系统功能。"
}

# --- Main Uninstallation Script ---
main_uninstall() {
    check_root
    
    log_warning "警告：此脚本将自动卸载 VLESS + sing-box + Cloudflare Tunnel 的所有组件。"
    log_warning "操作将立即开始，没有额外确认步骤！按 Ctrl+C 在3秒内取消..."
    sleep 3

    log_info "开始卸载..."

    load_install_details # Loads DOMAIN, ZONE_NAME, TUNNEL_ID, etc. from state file
    stop_and_disable_services
    
    # Attempt to delete CNAME via API using info from state file
    if [[ -n "$DOMAIN" && -n "$ZONE_NAME" ]]; then # Only attempt if we have enough info
        cleanup_cloudflare_dns_api
    else
        log_warning "状态文件中缺少 DOMAIN 或 ZONE_NAME，跳过 API DNS 清理。"
    fi

    # Delete the Tunnel entity itself using cloudflared CLI
    if [ -n "$TUNNEL_ID" ] || [ -n "$TUNNEL_NAME" ]; then
        local tunnel_ref_for_delete="${TUNNEL_ID:-$TUNNEL_NAME}" # Prefer ID
        log_info "尝试使用 cloudflared CLI 删除 Tunnel 实体: $tunnel_ref_for_delete"
        if cloudflared tunnel delete "$tunnel_ref_for_delete"; then
            log_success "Cloudflare Tunnel '$tunnel_ref_for_delete' 删除请求已提交."
        else log_warning "Cloudflare Tunnel '$tunnel_ref_for_delete' 删除请求失败. 可能需手动删除."; fi
    else log_warning "未从状态文件找到 Tunnel ID/名称, 无法通过 CLI 删除 Tunnel."; fi

    remove_files_and_dirs # This will also remove the state file
    list_dependencies
    log_success "卸载过程已完成."
    log_warning "请务必检查 Cloudflare Dashboard 确认 Tunnel 和 DNS 记录已清理."
}

main_uninstall "$@"
