#!/bin/bash

# Uninstallation script for VLESS + sing-box + Cloudflare Tunnel
# Author: AI Assistant (Reads config.cfg for API token, uses Cloudflare API for DNS)

# --- Configuration File for API Token ---
CONFIG_FILE_NAME="config.cfg"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/${CONFIG_FILE_NAME}"

# --- State File ---
STATE_FILE="/etc/sing-box/install_details.env"

# --- Global Variables ---
CLOUDFLARE_API_ENDPOINT="https://api.cloudflare.com/client/v4"
# CF_API_TOKEN and DOMAIN will be loaded

# --- Colors ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# --- Helper Functions ---
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

check_root() { if [ "$(id -u)" -ne 0 ]; then log_error "此脚本需要 root 权限运行。"; exit 1; fi; }

load_api_token_from_config() {
    if [ -n "$CF_API_TOKEN" ]; then return 0; fi # Already set
    if [ ! -f "$CONFIG_FILE" ]; then log_warning "配置文件 '$CONFIG_FILE' 未找到. 无法加载 API Token."; return 1; fi
    local token_val=$(grep -E "^CF_API_TOKEN\s*=" "$CONFIG_FILE" | head -n1 | cut -d'=' -f2- | sed 's/^[ \t"]*//;s/[ \t"]*$//')
    if [[ -n "$token_val" && "$token_val" != "your_cloudflare_api_token_here" ]]; then
        CF_API_TOKEN="$token_val"; log_info "从 '$CONFIG_FILE' 加载了 CF_API_TOKEN."; return 0
    else log_warning "在 '$CONFIG_FILE' 中未找到或无效的 CF_API_TOKEN."; CF_API_TOKEN=""; return 1; fi
}

load_install_details() {
    log_info "加载安装详情从: $STATE_FILE"
    if [ -f "$STATE_FILE" ]; then source "$STATE_FILE"; log_success "安装详情加载成功."; else
        log_warning "安装详情文件 '$STATE_FILE' 未找到."; # Set defaults for broader cleanup
        SINGBOX_SERVICE_FILE="/etc/systemd/system/sing-box.service"; CLOUDFLARED_SERVICE_FILE="/etc/systemd/system/cloudflared.service"
        SINGBOX_CONFIG_DIR="/etc/sing-box"; CLOUDFLARED_CONFIG_DIR="/etc/cloudflared"
        SINGBOX_EXECUTABLE="/usr/local/bin/sing-box"; CLOUDFLARED_EXECUTABLE="/usr/local/bin/cloudflared"
        CLOUDFLARED_CRED_DIR="/root/.cloudflared"
    fi
}

# --- Cloudflare API Functions (Copied from install script) ---
cf_api_call() {
    local method="$1" path="$2" data="$3" response_body http_code
    local curl_opts=(-s -w "%{http_code}" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json")
    if [[ "$method" == "GET" || "$method" == "DELETE" ]]; then
        response_body=$(curl "${curl_opts[@]}" -X "$method" "${CLOUDFLARE_API_ENDPOINT}${path}" -o /dev/stderr)
        http_code=$(echo "$response_body" | tail -n1); response_body=$(echo "$response_body" | sed '$d')
    elif [[ "$method" == "POST" || "$method" == "PUT" ]]; then
        response_body=$(curl "${curl_opts[@]}" -X "$method" --data "$data" "${CLOUDFLARE_API_ENDPOINT}${path}" -o /dev/stderr)
        http_code=$(echo "$response_body" | tail -n1); response_body=$(echo "$response_body" | sed '$d')
    else log_error "不支持的 HTTP 方法: $method"; return 1; fi
    if ! [[ "$http_code" =~ ^2[0-9]{2}$ ]]; then
        local errors=$(echo "$response_body" | jq -r '.errors | map(.message) | join(", ") // "未知API错误"')
        log_error "Cloudflare API 调用失败 ($http_code $method $path): $errors"; return 1
    fi; echo "$response_body"; return 0
}
get_zone_id() {
    local domain_name="$1" base_domain response zone_id
    base_domain=$(echo "$domain_name" | awk -F. '{OFS="."; if (NF > 2 && $(NF-1) ~ /^(com|co|org|net|gov|edu|ac)$/) {print $(NF-2),$(NF-1),$NF} else if (NF > 1) {print $(NF-1),$NF} else {print $0}}')
    log_info "为基础域名 '$base_domain' 获取 Zone ID..."
    response=$(cf_api_call "GET" "/zones?name=${base_domain}&status=active") || return 1
    zone_id=$(echo "$response" | jq -r '.result[0].id')
    if [[ -z "$zone_id" || "$zone_id" == "null" ]]; then log_error "未能找到域名 '$base_domain' 的 Zone ID."; return 1; fi
    log_success "获取到 Zone ID: $zone_id for $base_domain"; echo "$zone_id"; return 0
}
# --- End Cloudflare API Functions ---

stop_and_disable_services() { # Same as previous version
    log_info "停止并禁用服务..."
    for service in "sing-box" "cloudflared"; do
        if systemctl list-unit-files | grep -q "^${service}.service"; then
            systemctl stop "$service" >/dev/null 2>&1; systemctl disable "$service" >/dev/null 2>&1
            log_success "${service} 服务已停止并禁用."
        else log_warning "${service} 服务文件可能已被移除."; fi
    done; systemctl daemon-reload
}

remove_files_and_dirs() { # Same as previous version
    log_info "删除相关文件和目录..."
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
    for dir_path in "$_sbconfdir" "$_cfdconfdir"; do
        if [ -n "$dir_path" ] && [ -d "$dir_path" ]; then rm -rf "$dir_path"; log_success "删除目录: $dir_path"; fi
    done
    if [ -n "$_cfdcreddir" ] && [ -d "$_cfdcreddir" ]; then
        read -rp "$(echo -e "${YELLOW}是否删除 Cloudflare 凭证目录 (${_cfdcreddir})? (可能影响其他 Tunnel) [y/N]: ${NC}")" confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            if [ -n "$TUNNEL_ID" ] && [ -f "${_cfdcreddir}/${TUNNEL_ID}.json" ]; then
                 rm -f "${_cfdcreddir}/${TUNNEL_ID}.json"; log_success "删除: ${_cfdcreddir}/${TUNNEL_ID}.json"
            fi
            # Check if only cert.pem and logs remain before deleting the whole dir
            local files_in_cred_dir=$(ls -A "$_cfdcreddir" | grep -vE "(${TUNNEL_ID}\.json|cert\.pem|log\.log)" | wc -l)
            if [ "$files_in_cred_dir" -eq 0 ]; then # If no other important files
                rm -rf "$_cfdcreddir"; log_success "删除目录: $_cfdcreddir"
            else
                log_warning "$_cfdcreddir 包含其他文件, 未完全删除. 请手动检查."
            fi
        else log_info "保留目录: $_cfdcreddir"; fi
    fi; systemctl daemon-reload
}

cleanup_cloudflare_dns_api() {
    log_info "通过 API 清理 '$DOMAIN' 的 Cloudflare DNS CNAME 记录..."
    if ! load_api_token_from_config; then log_warning "无法加载 API Token. 跳过 API DNS 清理."; return 1; fi
    if [[ -z "$CF_API_TOKEN" ]]; then log_warning "未提供 CF_API_TOKEN. 跳过 API DNS 清理."; return 1; fi
    if [[ -z "$DOMAIN" ]]; then log_warning "域名未知. 无法清理 DNS."; return 1; fi

    ZONE_ID=$(get_zone_id "$DOMAIN") || { log_error "无法获取 Zone ID. 无法清理 DNS."; return 1; }
    existing_records_response=$(cf_api_call "GET" "/zones/${ZONE_ID}/dns_records?type=CNAME&name=${DOMAIN}")
    if [ $? -ne 0 ]; then log_error "查询现有 DNS 记录失败 (用于删除)."; return 1; fi

    record_id=$(echo "$existing_records_response" | jq -r '.result[] | select(.name == "'"$DOMAIN"'") | .id' | head -n 1)
    current_content=$(echo "$existing_records_response" | jq -r '.result[] | select(.name == "'"$DOMAIN"'") | .content' | head -n 1)

    if [[ -n "$record_id" && "$record_id" != "null" ]]; then
        if [[ "$current_content" == *".cfargotunnel.com"* ]]; then # Only delete if it looks like a tunnel record
            log_info "找到 CNAME (ID: $record_id, 内容: $current_content). 正在删除..."
            delete_response=$(cf_api_call "DELETE" "/zones/${ZONE_ID}/dns_records/${record_id}")
            if [ $? -eq 0 ] && echo "$delete_response" | jq -e '.success == true' > /dev/null; then log_success "CNAME (ID: $record_id) 删除成功."; else log_error "CNAME 删除失败."; fi
        else log_warning "找到 CNAME (ID: $record_id), 但内容 ($current_content) 不像 Tunnel 记录. 跳过 API 删除."; fi
    else log_info "未找到 '$DOMAIN' 的 CNAME 记录, 无需通过 API 删除."; fi
}

list_dependencies() { # Same as previous version
    log_info "已安装依赖: curl, jq, unzip, uuid-runtime, qrencode"
    log_info "如需卸载: sudo apt autoremove --purge curl jq unzip uuid-runtime qrencode"
}

# --- Main Uninstallation Script ---
main_uninstall() {
    check_root
    read -rp "$(echo -e "${RED}警告：此脚本将卸载所有组件. 是否继续? [y/N]: ${NC}")" confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then log_info "卸载已取消."; exit 0; fi

    load_install_details # Loads DOMAIN, TUNNEL_ID, etc.
    stop_and_disable_services
    
    cleanup_cloudflare_dns_api # Attempt to delete CNAME via API

    # Delete the Tunnel entity itself using cloudflared CLI
    if [ -n "$TUNNEL_ID" ] || [ -n "$TUNNEL_NAME" ]; then
        local tunnel_ref_for_delete="${TUNNEL_ID:-$TUNNEL_NAME}" # Prefer ID
        log_info "尝试使用 cloudflared CLI 删除 Tunnel 实体: $tunnel_ref_for_delete"
        if cloudflared tunnel delete "$tunnel_ref_for_delete"; then # Consider adding -y if supported for no prompt
            log_success "Cloudflare Tunnel '$tunnel_ref_for_delete' 删除请求已提交."
        else log_warning "Cloudflare Tunnel '$tunnel_ref_for_delete' 删除请求失败. 可能需手动删除."; fi
    else log_warning "未从状态文件找到 Tunnel ID/名称, 无法通过 CLI 删除 Tunnel."; fi

    remove_files_and_dirs
    list_dependencies
    log_success "卸载过程已完成."
    log_warning "请务必检查 Cloudflare Dashboard 确认 Tunnel 和 DNS 记录已清理."
}

main_uninstall
