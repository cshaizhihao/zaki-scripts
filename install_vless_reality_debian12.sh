#!/bin/bash

# ==============================================================================
# Xray VLESS-Reality 一键安装管理脚本 (Debian 12 专用优化版)
# 基于 V-Reborn-Caesar-3.4 重构
# 优化项：精简 OpenRC 逻辑，强化 Systemd 联动，适配 Debian 12 环境
# ==============================================================================

set -euo pipefail

# --- 全局常量 ---
readonly SCRIPT_VERSION="V-Debian12-Special"
readonly xray_config_path="/usr/local/etc/xray/config.json"
readonly xray_binary_path="/usr/local/bin/xray"
readonly address_file="/root/inbound_address.txt"

# --- 颜色定义 ---
readonly red='\e[91m' green='\e[92m' yellow='\e[93m'
readonly magenta='\e[95m' cyan='\e[96m' none='\e[0m'

# --- 辅助函数 ---
error() { echo -e "\n[✖] $1\n" >&2; }
info()  { echo -e "\n[!] $1\n"; }
success(){ echo -e "\n[✔] $1\n"; }

get_public_ip() {
    local ip
    for url in "https://api.ipify.org" "https://ip.sb" "https://checkip.amazonaws.com"; do
        ip=$(curl -4s --max-time 5 "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
    done
    error "无法获取公网 IP 地址。" && return 1
}

# --- 核心安装 ---
install_dependencies() {
    info "正在安装 Debian 12 必要依赖 (jq, curl, tar, unzip)..."
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y jq curl tar unzip iproute2 > /dev/null
    success "依赖安装完成"
}

install_xray_core() {
    info "开始安装 Xray 核心..."
    local arch machine="$(uname -m)"
    case "$machine" in
        x86_64|amd64) arch="64" ;;
        aarch64|arm64) arch="arm64-v8a" ;;
        *) error "不支持的架构: $machine"; return 1 ;;
    esac

    local tag=$(curl -fsSL "https://api.github.com/repos/XTLS/Xray-core/releases/latest" | jq -r .tag_name)
    info "目标版本: $tag"

    local tmpdir=$(mktemp -d)
    curl -fL "https://github.com/XTLS/Xray-core/releases/download/${tag}/Xray-linux-${arch}.zip" -o "$tmpdir/xray.zip"
    
    unzip -qo "$tmpdir/xray.zip" -d "$tmpdir"
    install -m 0755 "$tmpdir/xray" "$xray_binary_path"
    mkdir -p /usr/local/etc/xray /usr/local/share/xray
    
    # 安装 GeoData
    curl -fsSL -o /usr/local/share/xray/geoip.dat https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat
    curl -fsSL -o /usr/local/share/xray/geosite.dat https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat
    
    rm -rf "$tmpdir"
    success "Xray 核心及数据文件安装完成"
}

setup_systemd() {
    info "配置 Systemd 服务..."
    cat >/etc/systemd/system/xray.service <<'SYSTEMD'
[Unit]
Description=Xray Service
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
User=root
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
SYSTEMD
    systemctl daemon-reload
    systemctl enable xray
    success "Systemd 服务已就绪"
}

# --- 逻辑功能 ---
write_config() {
    local port=$1 uuid=$2 domain=$3 private_key=$4 public_key=$5 shortid="20220701"
    local inbound_json=$(jq -n \
        --argjson port "$port" --arg uuid "$uuid" --arg domain "$domain" \
        --arg private_key "$private_key" --arg public_key "$public_key" --arg shortid "$shortid" \
    '{
        "listen": "0.0.0.0", "port": $port, "protocol": "vless",
        "settings": { "clients": [{"id": $uuid, "flow": "xtls-rprx-vision"}], "decryption": "none" },
        "streamSettings": {
            "network": "tcp", "security": "reality",
            "realitySettings": {
                "show": false, "dest": ($domain + ":443"), "xver": 0,
                "serverNames": [$domain], "privateKey": $private_key, "publicKey": $public_key,
                "shortIds": [$shortid]
            }
        }
    }')

    if [[ ! -f "$xray_config_path" ]]; then
        mkdir -p "$(dirname "$xray_config_path")"
        echo '{ "log": { "loglevel": "warning" }, "inbounds": [], "outbounds": [{ "protocol": "freedom", "tag": "direct" }] }' > "$xray_config_path"
    fi

    local tmp=$(mktemp)
    jq --argjson new "$inbound_json" '.inbounds += [$new]' "$xray_config_path" > "$tmp" && mv "$tmp" "$xray_config_path"
}

run_install() {
    install_dependencies
    install_xray_core
    
    local port=443 uuid=$(cat /proc/sys/kernel/random/uuid) domain="hk.art.museum"
    local key_pair=$($xray_binary_path x25519)
    local priv=$(echo "$key_pair" | awk '/PrivateKey:/ {print $2}')
    local pub=$(echo "$key_pair" | awk '/Password:/ {print $2}')

    write_config "$port" "$uuid" "$domain" "$priv" "$pub"
    setup_systemd
    systemctl restart xray
    
    success "安装成功！"
    echo -e "端口: $port"
    echo -e "UUID: $uuid"
    echo -e "公钥: $pub"
}

# --- 极简菜单 ---
clear
echo -e "--- Xray VLESS-Reality (Debian 12 Special) ---"
echo "1. 立即安装"
echo "2. 卸载服务"
echo "0. 退出"
read -p "选择 [0-2]: " choice

case $choice in
    1) run_install ;;
    2) systemctl stop xray && rm -f /etc/systemd/system/xray.service && rm -rf /usr/local/etc/xray && success "已卸载" ;;
    *) exit 0 ;;
esac
