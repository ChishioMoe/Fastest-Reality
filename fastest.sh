#!/bin/bash

# ==============================================================================
# Xray VLESS-Reality & Shadowsocks 2022 多功能管理脚本
# 版本: Final v2.9.3 (SNI 优选版)
# 更新日志 (v2.9.3):
# - [新增] Reality 目标域名(SNI) 自动测速与优选功能
# - [优化] 集成 bc 依赖检查
# - [优化] 提升安装交互体验
# ==============================================================================

# --- Shell 严格模式 ---
set -euo pipefail

# --- 全局常量 ---
readonly SCRIPT_VERSION="Final v2.9.3"
readonly xray_config_path="/usr/local/etc/xray/config.json"
readonly xray_binary_path="/usr/local/bin/xray"
readonly xray_install_script_url="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"

# --- 颜色定义 ---
readonly red='\e[91m' green='\e[92m' yellow='\e[93m'
readonly magenta='\e[95m' cyan='\e[96m' none='\e[0m'

# --- 全局变量 ---
xray_status_info=""
is_quiet=false

# --- 辅助函数 ---
error() { 
    echo -e "\n$red[✖] $1$none\n" >&2
    
    case "$1" in
        *"网络"*|*"下载"*) 
            echo -e "$yellow提示: 检查网络连接或更换DNS$none" >&2 ;;
        *"权限"*|*"root"*) 
            echo -e "$yellow提示: 请使用 sudo 运行脚本$none" >&2 ;;
        *"端口"*) 
            echo -e "$yellow提示: 尝试使用其他端口号$none" >&2 ;;
    esac
}

info() { [[ "$is_quiet" = false ]] && echo -e "\n$yellow[!] $1$none\n"; }
success() { [[ "$is_quiet" = false ]] && echo -e "\n$green[✔] $1$none\n"; }
warning() { [[ "$is_quiet" = false ]] && echo -e "\n$yellow[⚠] $1$none\n"; }

spinner() {
    local pid="$1"
    local spinstr='|/-\'
    if [[ "$is_quiet" = true ]]; then
        wait "$pid"
        return
    fi
    while ps -p "$pid" > /dev/null; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep 0.1
        printf "\r"
    done
    printf "    \r"
}

get_public_ip() {
    local ip
    local attempts=0
    local max_attempts=2
    
    while [[ $attempts -lt $max_attempts ]]; do
        for cmd in "curl -4s --max-time 5" "wget -4qO- --timeout=5"; do
            for url in "https://api.ipify.org" "https://ip.sb" "https://checkip.amazonaws.com"; do
                ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
            done
        done
        ((attempts++))
        [[ $attempts -lt $max_attempts ]] && sleep 1
    done
    
    # IPv6 fallback
    for cmd in "curl -6s --max-time 5" "wget -6qO- --timeout=5"; do
        for url in "https://api64.ipify.org" "https://ip.sb"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
}

# --- 预检查与环境设置 ---
pre_check() {
    [[ "$(id -u)" != 0 ]] && error "错误: 您必须以root用户身份运行此脚本" && exit 1
    if [ ! -f /etc/debian_version ]; then error "错误: 此脚本仅支持 Debian/Ubuntu 及其衍生系统。" && exit 1; fi
    
    # 新增 bc 依赖检查 (用于浮点数比较)
    local dependencies=("jq" "curl" "bc")
    local need_install=false
    
    for dep in "${dependencies[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            need_install=true
            break
        fi
    done

    if [[ "$need_install" = true ]]; then
        info "检测到缺失的依赖 (jq/curl/bc)，正在尝试自动安装..."
        (DEBIAN_FRONTEND=noninteractive apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y jq curl bc iputils-ping) &> /dev/null &
        spinner $!
        
        # 再次检查
        for dep in "${dependencies[@]}"; do
            if ! command -v "$dep" &>/dev/null; then
                error "依赖 ($dep) 自动安装失败。请手动运行 'apt update && apt install -y jq curl bc' 后重试。"
                exit 1
            fi
        done
        success "依赖已成功安装。"
    fi
}

check_xray_status() {
    if [[ ! -f "$xray_binary_path" || ! -x "$xray_binary_path" ]]; then
        xray_status_info=" Xray 状态: ${red}未安装${none}"
        return
    fi
    local xray_version
    xray_version=$("$xray_binary_path" version 2>/dev/null | head -n 1 | awk '{print $2}' || echo "未知")
    local service_status
    if systemctl is-active --quiet xray 2>/dev/null; then
        service_status="${green}运行中${none}"
    else
        service_status="${yellow}未运行${none}"
    fi
    xray_status_info=" Xray 状态: ${green}已安装${none} | ${service_status} | 版本: ${cyan}${xray_version}${none}"
}

quick_status() {
    if [[ ! -f "$xray_binary_path" ]]; then
        echo -e " ${red}●${none} 未安装"
        return
    fi
    
    local status_icon
    if systemctl is-active --quiet xray 2>/dev/null; then
        status_icon="${green}●${none}"
    else
        status_icon="${red}●${none}"
    fi
    
    echo -e " $status_icon Xray $(systemctl is-active xray 2>/dev/null || echo "inactive")"
}

# --- SNI 优选功能 (新增) ---
get_best_sni() {
    local domains=(
        "www.salesforce.com" "www.costco.com" "www.bing.com" 
        "learn.microsoft.com" "swdist.apple.com" "www.tesla.com" 
        "www.softbank.jp" "www.homedepot.com" "scholar.google.com" 
        "itunes.apple.com" "www.amazon.com" "dl.google.com" 
        "addons.mozilla.org" "www.yahoo.co.jp" 
        "www.lovelive-anime.jp" "www.mtr.com.hk"
    )
    
    # 打印到 stderr 以便用户看到过程，但函数只返回域名字符串
    echo -e "\n${cyan}正在对 16 个常用 SNI 域名进行延迟测试 (每域名 Ping 4 次)...${none}" >&2
    echo "------------------------------------------------------" >&2
    printf "%-25s | %-10s | %-10s\n" "域名" "平均延迟" "抖动" >&2
    
    local min_latency=9999
    local best_domain="learn.microsoft.com" # 默认兜底
    local best_jitter=0

    for domain in "${domains[@]}"; do
        # 优化：Ping 4次，超时1秒，加快速度
        local res=$(ping -c 4 -W 1 -q "$domain" 2>/dev/null | tail -1)
        if [ -n "$res" ]; then
            # 提取 avg(5) 和 mdev(7)
            local avg=$(echo "$res" | cut -d '/' -f 5)
            local jitter=$(echo "$res" | cut -d '/' -f 7 | cut -d ' ' -f 1)
            
            # 如果 avg 为空（可能格式不同），跳过
            if [[ -z "$avg" ]]; then continue; fi

            printf "%-25s | %-8s ms | %-8s ms\n" "$domain" "$avg" "$jitter" >&2
            
            # 使用 bc 进行浮点数比较
            if (( $(echo "$avg < $min_latency" | bc -l) )); then
                min_latency=$avg
                best_domain=$domain
                best_jitter=$jitter
            fi
        else
            printf "%-25s | %-10s\n" "$domain" "超时/不可达" >&2
        fi
    done
    echo "------------------------------------------------------" >&2
    echo -e "${green}推荐最佳 SNI: $best_domain${none} (延迟: ${min_latency}ms)" >&2
    
    # 仅输出域名供脚本捕获
    echo "$best_domain"
}

# --- 核心配置生成函数 ---
generate_ss_key() {
    openssl rand -base64 16
}

build_vless_inbound() {
    local port="$1" uuid="$2" domain="$3" private_key="$4" public_key="$5" shortid="20220701"
    jq -n --argjson port "$port" --arg uuid "$uuid" --arg domain "$domain" --arg private_key "$private_key" --arg public_key "$public_key" --arg shortid "$shortid" \
    '{ "listen": "0.0.0.0", "port": $port, "protocol": "vless", "settings": {"clients": [{"id": $uuid, "flow": "xtls-rprx-vision"}], "decryption": "none"}, "streamSettings": {"network": "tcp", "security": "reality", "realitySettings": {"show": false, "dest": ($domain + ":443"), "xver": 0, "serverNames": [$domain], "privateKey": $private_key, "publicKey": $public_key, "shortIds": [$shortid]}}, "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"]} }'
}

build_ss_inbound() {
    local port="$1" password="$2"
    jq -n --argjson port "$port" --arg password "$password" \
    '{ "listen": "0.0.0.0", "port": $port, "protocol": "shadowsocks", "settings": {"method": "2022-blake3-aes-128-gcm", "password": $password} }'
}

write_config() {
    local inbounds_json="$1"
    local config_content
    
    config_content=$(jq -n --argjson inbounds "$inbounds_json" \
    '{
      "log": {"loglevel": "warning"},
      "inbounds": $inbounds,
      "outbounds": [
        {
          "protocol": "freedom",
          "settings": {
            "domainStrategy": "UseIPv4v6"
          }
        }
      ]
    }')
    
    if ! echo "$config_content" | jq . >/dev/null 2>&1; then
        error "生成的配置文件格式错误！"
        return 1
    fi
    
    echo "$config_content" > "$xray_config_path"
    
    chmod 644 "$xray_config_path"
    chown root:root "$xray_config_path"
}

execute_official_script() {
    local args="$1"
    local script_content
    
    script_content=$(curl -L "$xray_install_script_url")
    if [[ -z "$script_content" || ! "$script_content" =~ "install-release" ]]; then
        error "下载 Xray 官方安装脚本失败或内容异常！请检查网络连接。"
        return 1
    fi
    
    echo "$script_content" | bash -s -- $args &> /dev/null &
    spinner $!
    if ! wait $!; then
        return 1
    fi
}

run_core_install() {
    info "正在下载并安装 Xray 核心..."
    if ! execute_official_script "install"; then
        error "Xray 核心安装失败！"
        return 1
    fi
    
    info "正在更新 GeoIP 和 GeoSite 数据文件..."
    if ! execute_official_script "install-geodata"; then
        error "Geo-data 更新失败！"
        info "这通常不影响核心功能，您可以稍后手动更新。"
    fi
    
    success "Xray 核心及数据文件已准备就绪。"
}

# --- 输入验证与交互函数 ---
is_valid_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

is_port_available() {
    local port="$1"
    is_valid_port "$port" || return 1
    if ss -tlpn 2>/dev/null | grep -q ":$port "; then
        warning "端口 $port 已被占用，建议选择其他端口"
        return 1
    fi
