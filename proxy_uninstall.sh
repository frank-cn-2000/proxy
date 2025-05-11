#!/bin/bash

# Uninstallation script for VLESS + sing-box + Cloudflare Tunnel
# Author: AI Assistant

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- State File ---
STATE_FILE="/etc/sing-box/install_details.env"

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

load_install_details() {
    log_info "正在加载安装详情从: $STATE_FILE"
    if [ -f "$STATE_FILE" ]; then
        source "$STATE_FILE"
        log_success "安装详情加载成功。"
        if [ -z "$TUNNEL_ID" ] && [ -z "$TUNNEL_NAME" ]; then
            log_warning "状态文件中未找到 TUNNEL_ID 或 TUNNEL_NAME。可能无法自动清理 Cloudflare Tunnel。"
        fi
        if [ -z "$DOMAIN" ]; then
            log_warning "状态文件中未找到 DOMAIN。可能无法自动清理 Cloudflare DNS 记录。"
        fi
    else
        log_warning "安装详情文件 '$STATE_FILE' 未找到。"
        log_warning "将尝试通用卸载路径，但 Cloudflare 资源和部分文件可能需要手动清理。"
        # Set default paths if state file is missing, for basic cleanup attempt
        SINGBOX_SERVICE_FILE="/etc/systemd/system/sing-box.service"
        CLOUDFLARED_SERVICE_FILE="/etc/systemd/system/cloudflared.service"
        SINGBOX_CONFIG_DIR="/etc/sing-box" # Also contains state file
        CLOUDFLARED_CONFIG_DIR="/etc/cloudflared"
        SINGBOX_EXECUTABLE="/usr/local/bin/sing-box"
        CLOUDFLARED_EXECUTABLE="/usr/local/bin/cloudflared"
        CLOUDFLARED_CREDENTIALS_DIR="/root/.cloudflared"
    fi
}

stop_and_disable_services() {
    log_info "正在停止并禁用服务..."
    SERVICES_TO_STOP=("sing-box" "cloudflared")
    for service in "${SERVICES_TO_STOP[@]}"; do
        if systemctl list-unit-files | grep -q "^${service}.service"; then
            log_info "停止 ${service} 服务..."
            systemctl stop "$service" >/dev/null 2>&1
            log_info "禁用 ${service} 服务..."
            systemctl disable "$service" >/dev/null 2>&1
            log_success "${service} 服务已停止并禁用。"
        else
            log_warning "${service} 服务文件可能已被移除或未安装。"
        fi
    done
    systemctl daemon-reload # Important after disabling services
}

remove_files_and_dirs() {
    log_info "正在删除相关文件和目录..."

    # Use variables from state file if available, otherwise use defaults
    _sbsvc=${SINGBOX_SERVICE_FILE:-/etc/systemd/system/sing-box.service}
    _cfdsvc=${CLOUDFLARED_SERVICE_FILE:-/etc/systemd/system/cloudflared.service}
    _sbexe=${SINGBOX_EXECUTABLE:-/usr/local/bin/sing-box}
    _cfdexe=${CLOUDFLARED_EXECUTABLE:-/usr/local/bin/cloudflared}
    _sbconfdir=${SINGBOX_CONFIG_DIR:-/etc/sing-box}
    _cfdconfdir=${CLOUDFLARED_CONFIG_DIR:-/etc/cloudflared}
    _cfdcreddir=${CLOUDFLARED_CREDENTIALS_DIR:-/root/.cloudflared}


    FILES_TO_REMOVE=(
        "$_sbsvc"
        "$_cfdsvc"
        "$_sbexe"
        "$_cfdexe"
    )
    DIRS_TO_REMOVE=(
        "$_sbconfdir" # This includes the state file itself
        "$_cfdconfdir"
    )

    for file_path in "${FILES_TO_REMOVE[@]}"; do
        if [ -n "$file_path" ] && [ -f "$file_path" ]; then
            rm -f "$file_path"
            log_success "已删除文件: $file_path"
        elif [ -n "$file_path" ]; then
            log_warning "文件未找到或已被删除: $file_path"
        fi
    done

    for dir_path in "${DIRS_TO_REMOVE[@]}"; do
        if [ -n "$dir_path" ] && [ -d "$dir_path" ]; then
            rm -rf "$dir_path"
            log_success "已删除目录: $dir_path"
        elif [ -n "$dir_path" ]; then
            log_warning "目录未找到或已被删除: $dir_path"
        fi
    done
    
    if [ -n "$_cfdcreddir" ] && [ -d "$_cfdcreddir" ]; then
        echo -e "${YELLOW}Cloudflare 凭证目录位于: ${_cfdcreddir}${NC}"
        echo -e "${YELLOW}此目录可能包含您 Cloudflare 账户下其他 Tunnel 的凭证（例如 cert.pem）。${NC}"
        
        SPECIFIC_TUNNEL_CERT_JSON=""
        if [ -n "$TUNNEL_ID" ]; then # TUNNEL_ID is from loaded state file
            SPECIFIC_TUNNEL_CERT_JSON="${_cfdcreddir}/${TUNNEL_ID}.json"
        fi

        if [ -n "$SPECIFIC_TUNNEL_CERT_JSON" ] && [ -f "$SPECIFIC_TUNNEL_CERT_JSON" ]; then
            read -rp "$(echo -e ${YELLOW}"是否删除此部署特定的 Tunnel 凭证文件 (${SPECIFIC_TUNNEL_CERT_JSON})? [y/N]: "${NC})" confirm_delete_specific_cert
            if [[ "$confirm_delete_specific_cert" =~ ^[Yy]$ ]]; then
                rm -f "$SPECIFIC_TUNNEL_CERT_JSON"
                log_success "已删除特定 Tunnel 凭证文件: $SPECIFIC_TUNNEL_CERT_JSON"
            else
                log_info "保留特定 Tunnel 凭证文件: $SPECIFIC_TUNNEL_CERT_JSON"
            fi
        else
            log_info "未找到此部署特定的 Tunnel 凭证文件 (${TUNNEL_ID}.json)，或 TUNNEL_ID 未知。"
        fi

        read -rp "$(echo -e ${YELLOW}"是否考虑删除整个 Cloudflare 凭证目录 (${_cfdcreddir})? (请谨慎!) [y/N]: "${NC})" confirm_delete_creds_dir
        if [[ "$confirm_delete_creds_dir" =~ ^[Yy]$ ]]; then
            rm -rf "$_cfdcreddir"
            log_success "已删除 Cloudflare 凭证目录: $_cfdcreddir"
        else
            log_info "保留 Cloudflare 凭证目录: $_cfdcreddir"
        fi
    fi

    systemctl daemon-reload # After removing service files
}

cleanup_cloudflare_tunnel() {
    if ! command -v cloudflared >/dev/null 2>&1; then
        log_warning "Cloudflared 命令未找到。无法自动清理 Cloudflare Tunnel。"
        if [ -n "$TUNNEL_NAME" ]; then log_warning "部署时 Tunnel 名称可能为: $TUNNEL_NAME"; fi
        if [ -n "$TUNNEL_ID" ]; then log_warning "部署时 Tunnel ID 可能为: $TUNNEL_ID"; fi
        if [ -n "$DOMAIN" ]; then log_warning "相关域名为: $DOMAIN"; fi
        log_warning "请登录您的 Cloudflare Dashboard (Zero Trust -> Access -> Tunnels) 手动删除。"
        return
    fi

    log_info "尝试清理 Cloudflare Tunnel..."
    
    if ! cloudflared tunnel list > /dev/null 2>&1; then
        log_warning "Cloudflared 未登录或无法访问API。请运行 'cloudflared tunnel login' 并授权。"
        log_warning "如果您已登录但仍看到此消息，可能是 Cloudflare API 访问问题。"
        # Allow to proceed if user has TUNNEL_ID/NAME to try deletion.
    fi

    TUNNEL_TO_DELETE=""
    # Prefer TUNNEL_ID if available, as it's more specific
    if [ -n "$TUNNEL_ID" ]; then
        TUNNEL_TO_DELETE="$TUNNEL_ID"
        log_info "准备删除/清理 Tunnel ID: $TUNNEL_TO_DELETE"
    elif [ -n "$TUNNEL_NAME" ]; then
        TUNNEL_TO_DELETE="$TUNNEL_NAME"
        log_info "准备删除/清理 Tunnel 名称: $TUNNEL_TO_DELETE"
    else
        log_warning "未从状态文件找到 Tunnel ID 或名称。无法自动删除 Cloudflare Tunnel。"
        log_warning "请登录您的 Cloudflare Dashboard 手动删除。"
        return
    fi

    log_info "尝试使用 'cloudflared tunnel cleanup ${TUNNEL_TO_DELETE}' 清理 Tunnel 及其 DNS 记录..."
    if cloudflared tunnel cleanup "${TUNNEL_TO_DELETE}"; then
        log_success "Cloudflare Tunnel '${TUNNEL_TO_DELETE}' 及相关 DNS 记录（如果由 Tunnel 创建）已成功提交清理请求。"
        # Cleanup might not be instant, but the command itself succeeded.
    else
        log_warning "Cloudflare Tunnel '${TUNNEL_TO_DELETE}' 清理命令执行失败。"
        log_info "这可能是因为它已被删除，或权限不足，或名称/ID不匹配。"
        log_info "尝试使用 'cloudflared tunnel delete ${TUNNEL_TO_DELETE}'..."
        if cloudflared tunnel delete "${TUNNEL_TO_DELETE}"; then
            log_success "Cloudflare Tunnel '${TUNNEL_TO_DELETE}' 删除命令成功提交。"
        else
            log_warning "Cloudflare Tunnel '${TUNNEL_TO_DELETE}' 删除命令也失败了。"
        fi
        log_warning "请登录 Cloudflare Dashboard 手动检查并删除 Tunnel 和相关的 DNS CNAME 记录。"
        if [ -n "$DOMAIN" ]; then log_warning "检查域名 '$DOMAIN' 的 DNS CNAME 记录。"; fi
    fi
}

list_dependencies() {
    log_info "此部署脚本可能已安装以下依赖项:"
    echo -e "${YELLOW}  curl, jq, unzip, uuid-runtime, qrencode${NC}"
    log_info "这些是通用工具，可能被系统上其他应用使用。"
    log_info "如果您确定不再需要它们，可以运行以下命令手动卸载:"
    echo -e "${YELLOW}  sudo apt autoremove --purge curl jq unzip uuid-runtime qrencode${NC}"
    log_warning "请谨慎操作，确保不会影响其他系统功能。"
}

# --- Main Uninstallation Script ---
main_uninstall() {
    check_root
    
    echo -e "${RED}警告：此脚本将尝试卸载 VLESS + sing-box + Cloudflare Tunnel 的所有组件。${NC}"
    read -rp "$(echo -e ${YELLOW}"是否继续卸载? [y/N]: "${NC})" confirm_uninstall
    if [[ ! "$confirm_uninstall" =~ ^[Yy]$ ]]; then
        log_info "卸载已取消。"
        exit 0
    fi

    load_install_details
    stop_and_disable_services
    cleanup_cloudflare_tunnel # Attempt to clean Cloudflare resources first
    remove_files_and_dirs   # Then remove local files
    list_dependencies

    log_success "卸载过程已完成。"
    log_info "建议重启服务器以确保所有更改生效，或至少重新加载 systemd: systemctl daemon-reload"
    log_warning "请务必检查 Cloudflare Dashboard 以确认 Tunnel 和 DNS 记录已按预期清理。"
}

main_uninstall
