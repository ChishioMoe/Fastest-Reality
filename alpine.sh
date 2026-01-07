#!/bin/bash

# ==============================================================================
# Xray VLESS-Reality & Shadowsocks 2022 多功能管理脚本 (Alpine Linux 版)
# 版本: Alpine v1.0 (基于原版 v2.9.3 修改)
# 适配: Alpine Linux 3.10+ (OpenRC)
# ==============================================================================

# --- Shell 严格模式 ---
set -euo pipefail

# --- 全局常量 ---
readonly SCRIPT_VERSION="Alpine v1.0"
readonly xray_config_path="/usr/local/etc/xray/config.json"
readonly xray_binary_path="/usr/local/bin/xray"
readonly xray_install_script_url="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"
readonly xray_log_file="/var/log/xray.log"
readonly xray_err_file="/var/log/xray.error.log"

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
    while ps -o pid | grep -q "^[[:space:]]*$pid$"; do
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
    
    if [ ! -f /etc/alpine-release ]; then 
        error "错误: 此脚本仅支持 Alpine Linux。" 
        exit 1
    fi
    
    # Alpine 依赖检查
    # coreutils: 提供 stdbuf, timeout 等标准工具
    # iproute2: 提供 ss 命令
    # iputils: 提供标准 ping
    # bc: 浮点运算
    local dependencies=("jq" "curl" "bc" "openssl" "ss" "ping")
    local need_install=false
    
    # 简单的命令检查
    if ! command -v jq &>/dev/null || \
       ! command -v curl &>/dev/null || \
       ! command -v bc &>/dev/null || \
       ! command -v openssl &>/dev/null || \
       ! command -v ss &>/dev/null || \
       ! command -v ping &>/dev/null; then
        need_install=true
    fi

    if [[ "$need_install" = true ]]; then
        info "正在安装必要的依赖 (jq, curl, bc, openssl, iproute2, iputils)..."
        # 强制安装 bash 以确保环境统一
        (apk update && apk add --no-cache bash jq curl bc openssl iproute2 iputils coreutils ca-certificates tzdata) &> /dev/null &
        spinner $!
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
    # OpenRC 状态检查
    if rc-service xray status 2>/dev/null | grep -q "started"; then
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
    if rc-service xray status 2>/dev/null | grep -q "started"; then
        status_icon="${green}●${none}"
        echo -e " $status_icon Xray (running)"
    else
        status_icon="${red}●${none}"
        echo -e " $status_icon Xray (stopped)"
    fi
}

# --- OpenRC 服务配置 (关键修改) ---
install_openrc_service() {
    info "配置 OpenRC 服务..."
    cat > /etc/init.d/xray <<EOF
#!/sbin/openrc-run

name="xray"
description="Xray Platform"
command="$xray_binary_path"
command_args="run -c $xray_config_path"
command_background=true
pidfile="/run/xray.pid"
output_log="$xray_log_file"
error_log="$xray_err_file"

depend() {
    need net
    after firewall
}
EOF
    chmod +x /etc/init.d/xray
    rc-update add xray default
    success "OpenRC 服务配置完成"
}

# --- SNI 优选功能 ---
get_best_sni() {
    local domains=(
        "www.salesforce.com" "www.costco.com" "www.bing.com" 
        "learn.microsoft.com" "swdist.apple.com" "www.tesla.com" 
        "www.softbank.jp" "www.homedepot.com" "scholar.google.com" 
        "itunes.apple.com" "www.amazon.com" "dl.google.com" 
        "addons.mozilla.org" "www.yahoo.co.jp" 
        "www.lovelive-anime.jp" "www.mtr.com.hk"
    )
    
    echo -e "\n${cyan}正在对 16 个常用 SNI 域名进行延迟测试...${none}" >&2
    echo "------------------------------------------------------" >&2
    printf "%-25s | %-10s | %-10s\n" "域名" "平均延迟" "抖动" >&2
    
    local min_latency=9999
    local best_domain="learn.microsoft.com"
    local best_jitter=0

    for domain in "${domains[@]}"; do
        local res=$(ping -c 4 -W 1 -q "$domain" 2>/dev/null | tail -1)
        if [ -n "$res" ]; then
            local avg=$(echo "$res" | cut -d '/' -f 5)
            local jitter=$(echo "$res" | cut -d '/' -f 7 | cut -d ' ' -f 1)
            
            if [[ -z "$avg" ]]; then continue; fi

            printf "%-25s | %-8s ms | %-8s ms\n" "$domain" "$avg" "$jitter" >&2
            
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
    
    mkdir -p /usr/local/etc/xray
    echo "$config_content" > "$xray_config_path"
    chmod 644 "$xray_config_path"
}

execute_official_script() {
    local args="$1"
    local script_content
    
    script_content=$(curl -L "$xray_install_script_url")
    if [[ -z "$script_content" || ! "$script_content" =~ "install-release" ]]; then
        error "下载 Xray 官方安装脚本失败！"
        return 1
    fi
    
    # 官方脚本在 Alpine 下可能无法正确处理 systemd，但可以下载二进制文件
    # 我们忽略它的服务安装部分，稍后手动配置 OpenRC
    echo "$script_content" | bash -s -- $args &> /dev/null &
    spinner $!
    wait $!
}

run_core_install() {
    info "正在下载并安装 Xray 核心..."
    if ! execute_official_script "install"; then
        error "Xray 核心安装失败！"
        return 1
    fi
    
    info "正在更新 GeoIP 和 GeoSite..."
    execute_official_script "install-geodata"
    
    # Alpine 特有：安装服务文件
    install_openrc_service
    
    success "Xray 核心安装完成。"
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
        warning "端口 $port 已被占用"
        return 1
    fi
    return 0
}

is_valid_domain() {
    local domain="$1"
    [[ "$domain" =~ ^[a-zA-Z0-9-]{1,63}(\.[a-zA-Z0-9-]{1,63})+$ ]] && [[ "$domain" != *--* ]]
}

prompt_for_vless_config() {
    local -n p_port="$1" p_uuid="$2" p_sni="$3"
    local default_port="${4:-443}"

    while true; do
        read -p "$(echo -e " -> VLESS 端口 (默认: ${cyan}${default_port}${none}): ")" p_port || true
        [[ -z "$p_port" ]] && p_port="$default_port"
        if is_port_available "$p_port"; then break; fi
    done

    read -p "$(echo -e " -> UUID (回车生成随机): ")" p_uuid || true
    if [[ -z "$p_uuid" ]]; then
        p_uuid=$(cat /proc/sys/kernel/random/uuid)
        info "生成随机UUID: ${cyan}${p_uuid}${none}"
    fi

    local default_sni="learn.microsoft.com"
    local use_auto_sni=""
    
    read -p "$(echo -e " -> 自动优选 SNI 域名? [Y/n] (默认: ${cyan}Y${none}): ")" use_auto_sni || true
    [[ -z "$use_auto_sni" ]] && use_auto_sni="y"

    if [[ "$use_auto_sni" =~ ^[yY]$ ]]; then
        default_sni=$(get_best_sni)
    fi

    while true; do
        read -p "$(echo -e " -> SNI域名 (默认: ${cyan}${default_sni}${none}): ")" p_sni || true
        [[ -z "$p_sni" ]] && p_sni="$default_sni"
        if is_valid_domain "$p_sni"; then break; else error "域名无效"; fi
    done
}

prompt_for_ss_config() {
    local -n p_port="$1" p_pass="$2"
    local default_port="${3:-8388}"

    while true; do
        read -p "$(echo -e " -> Shadowsocks 端口 (默认: ${cyan}${default_port}${none}): ")" p_port || true
        [[ -z "$p_port" ]] && p_port="$default_port"
        if is_port_available "$p_port"; then break; fi
    done
    
    read -p "$(echo -e " -> Shadowsocks 密钥 (回车生成随机): ")" p_pass || true
    if [[ -z "$p_pass" ]]; then
        p_pass=$(generate_ss_key)
        info "生成随机密钥: ${cyan}${p_pass}${none}"
    fi
}

# --- 菜单功能函数 ---
draw_divider() {
    printf "%0.s─" {1..48}
    printf "\n"
}

draw_menu_header() {
    clear
    echo -e "${cyan} Xray VLESS-Reality & SS-2022 (Alpine 版)${none}"
    echo -e "${yellow} Version: ${SCRIPT_VERSION}${none}"
    draw_divider
    check_xray_status
    echo -e "${xray_status_info}"
    quick_status 
    draw_divider
}

press_any_key_to_continue() {
    echo ""
    read -n 1 -s -r -p " 按任意键返回主菜单..." || true
}

install_menu() {
    local vless_exists="" ss_exists=""
    if [[ -f "$xray_config_path" ]]; then
        vless_exists=$(jq '.inbounds[] | select(.protocol == "vless")' "$xray_config_path" 2>/dev/null || true)
        ss_exists=$(jq '.inbounds[] | select(.protocol == "shadowsocks")' "$xray_config_path" 2>/dev/null || true)
    fi
    
    draw_menu_header
    if [[ -n "$vless_exists" && -n "$ss_exists" ]]; then
        success "已安装双协议。"
        return
    elif [[ -n "$vless_exists" ]]; then
        info "已安装 VLESS"
        echo "1. 追加安装 Shadowsocks"
        echo "2. 重装 VLESS"
        echo "0. 返回"
        read -p "选择: " choice
        case "$choice" in 1) add_ss_to_vless ;; 2) install_vless_only ;; 0) return ;; esac
    elif [[ -n "$ss_exists" ]]; then
        info "已安装 Shadowsocks"
        echo "1. 追加安装 VLESS"
        echo "2. 重装 Shadowsocks"
        echo "0. 返回"
        read -p "选择: " choice
        case "$choice" in 1) add_vless_to_ss ;; 2) install_ss_only ;; 0) return ;; esac
    else
        echo "1. 仅 VLESS-Reality"
        echo "2. 仅 Shadowsocks-2022"
        echo "3. 双协议安装"
        echo "0. 返回"
        read -p "选择: " choice
        case "$choice" in 1) install_vless_only ;; 2) install_ss_only ;; 3) install_dual ;; 0) return ;; esac
    fi
}

add_ss_to_vless() {
    info "追加 Shadowsocks..."
    local vless_inbound vless_port default_ss_port ss_port ss_password ss_inbound
    vless_inbound=$(jq '.inbounds[] | select(.protocol == "vless")' "$xray_config_path")
    vless_port=$(echo "$vless_inbound" | jq -r '.port')
    default_ss_port=$([[ "$vless_port" == "443" ]] && echo "8388" || echo "$((vless_port + 1))")
    
    prompt_for_ss_config ss_port ss_password "$default_ss_port"
    ss_inbound=$(build_ss_inbound "$ss_port" "$ss_password")
    write_config "[$vless_inbound, $ss_inbound]"
    if ! restart_xray; then return 1; fi
    success "完成！"
    view_all_info
}

add_vless_to_ss() {
    info "追加 VLESS..."
    local ss_inbound ss_port default_vless_port vless_port vless_uuid vless_domain key_pair private_key public_key vless_inbound
    ss_inbound=$(jq '.inbounds[] | select(.protocol == "shadowsocks")' "$xray_config_path")
    ss_port=$(echo "$ss_inbound" | jq -r '.port')
    default_vless_port=$([[ "$ss_port" == "8388" ]] && echo "443" || echo "$((ss_port - 1))")

    prompt_for_vless_config vless_port vless_uuid vless_domain "$default_vless_port"
    key_pair=$("$xray_binary_path" x25519)
    private_key=$(echo "$key_pair" | awk '/PrivateKey:/ {print $2}')
    public_key=$(echo "$key_pair" | awk '/Password:/ {print $2}')

    vless_inbound=$(build_vless_inbound "$vless_port" "$vless_uuid" "$vless_domain" "$private_key" "$public_key")
    write_config "[$vless_inbound, $ss_inbound]"
    if ! restart_xray; then return 1; fi
    success "完成！"
    view_all_info
}

install_vless_only() {
    local port uuid domain
    prompt_for_vless_config port uuid domain
    run_install_vless "$port" "$uuid" "$domain"
}

install_ss_only() {
    local port password
    prompt_for_ss_config port password
    run_install_ss "$port" "$password"
}

install_dual() {
    local vless_port vless_uuid vless_domain ss_port ss_password
    prompt_for_vless_config vless_port vless_uuid vless_domain
    
    local default_ss_port
    [[ "$vless_port" == "443" ]] && default_ss_port=8388 || default_ss_port=$((vless_port + 1))
    
    prompt_for_ss_config ss_port ss_password "$default_ss_port"
    run_install_dual "$vless_port" "$vless_uuid" "$vless_domain" "$ss_port" "$ss_password"
}

update_xray() {
    if [[ ! -f "$xray_binary_path" ]]; then error "未安装 Xray。" && return; fi
    info "正在更新..."
    run_core_install
    if ! restart_xray; then return 1; fi
    success "更新成功！"
}

uninstall_xray() {
    if [[ ! -f "$xray_binary_path" ]]; then error "未安装 Xray。" && return; fi
    read -p "确定卸载? [Y/n]: " confirm || true
    if [[ "$confirm" =~ ^[nN]$ ]]; then return; fi
    
    info "停止服务..."
    rc-service xray stop || true
    rc-update del xray || true
    rm -f /etc/init.d/xray
    rm -f "$xray_binary_path"
    rm -rf /usr/local/etc/xray
    rm -f /usr/local/share/xray/geosite.dat
    rm -f /usr/local/share/xray/geoip.dat
    rm -f ~/xray_subscription_info.txt
    success "卸载完成。"
}

restart_xray() {
    if [[ ! -f "$xray_binary_path" ]]; then error "未安装 Xray。" && return 1; fi
    info "重启服务..."
    if ! rc-service xray restart; then
        error "重启失败！"
        cat "$xray_err_file" | tail -5
        return 1
    fi
    sleep 2
    if rc-service xray status | grep -q "started"; then
        success "服务已重启！"
    else
        error "启动失败，日志:"
        cat "$xray_err_file" | tail -5
        return 1
    fi
}

view_xray_log() {
    if [[ ! -f "$xray_binary_path" ]]; then error "未安装 Xray。" && return; fi
    info "正在显示实时日志 (Ctrl+C 退出)..."
    if [ -f "$xray_log_file" ]; then
        tail -f "$xray_log_file" "$xray_err_file"
    else
        echo "日志文件尚未生成。"
    fi
}

view_all_info() {
    if [ ! -f "$xray_config_path" ]; then
        [[ "$is_quiet" = true ]] && return
        error "配置文件不存在。"
        return
    fi
    
    [[ "$is_quiet" = false ]] && clear && echo -e "${cyan} Xray 配置信息${none}" && draw_divider
    local ip=$(get_public_ip)
    
    # 获取 VLESS 信息
    local vless_inbound=$(jq '.inbounds[] | select(.protocol == "vless")' "$xray_config_path" 2>/dev/null || true)
    if [[ -n "$vless_inbound" ]]; then
        local uuid=$(echo "$vless_inbound" | jq -r '.settings.clients[0].id')
        local port=$(echo "$vless_inbound" | jq -r '.port')
        local domain=$(echo "$vless_inbound" | jq -r '.streamSettings.realitySettings.serverNames[0]')
        local public_key=$(echo "$vless_inbound" | jq -r '.streamSettings.realitySettings.publicKey')
        local shortid=$(echo "$vless_inbound" | jq -r '.streamSettings.realitySettings.shortIds[0]')
        local link="vless://${uuid}@${ip}:${port}?flow=xtls-rprx-vision&encryption=none&type=tcp&security=reality&sni=${domain}&fp=chrome&pbk=${public_key}&sid=${shortid}#Alpine-Xray"
        
        echo -e "${green}[VLESS]${none}"
        echo "链接: $link"
        [[ "$is_quiet" = false ]] && echo "SNI: $domain | PBK: $public_key"
    fi

    # 获取 SS 信息
    local ss_inbound=$(jq '.inbounds[] | select(.protocol == "shadowsocks")' "$xray_config_path" 2>/dev/null || true)
    if [[ -n "$ss_inbound" ]]; then
        local port=$(echo "$ss_inbound" | jq -r '.port')
        local method=$(echo "$ss_inbound" | jq -r '.settings.method')
        local password=$(echo "$ss_inbound" | jq -r '.settings.password')
        local user_info=$(echo -n "${method}:${password}" | base64 -w 0)
        local link="ss://${user_info}@${ip}:${port}#Alpine-SS"
        
        echo -e "\n${green}[Shadowsocks]${none}"
        echo "链接: $link"
        [[ "$is_quiet" = false ]] && echo "密码: $password"
    fi
}

run_install_vless() {
    local port="$1" uuid="$2" domain="$3"
    run_core_install || exit 1
    local key_pair=$("$xray_binary_path" x25519)
    local private_key=$(echo "$key_pair" | awk '/PrivateKey:/ {print $2}')
    local public_key=$(echo "$key_pair" | awk '/Password:/ {print $2}')
    local vless_inbound=$(build_vless_inbound "$port" "$uuid" "$domain" "$private_key" "$public_key")
    write_config "[$vless_inbound]"
    if ! restart_xray; then exit 1; fi
    success "VLESS 安装成功！"
    view_all_info
}

run_install_ss() {
    local port="$1" password="$2"
    run_core_install || exit 1
    local ss_inbound=$(build_ss_inbound "$port" "$password")
    write_config "[$ss_inbound]"
    if ! restart_xray; then exit 1; fi
    success "SS 安装成功！"
    view_all_info
}

run_install_dual() {
    local vless_port="$1" vless_uuid="$2" vless_domain="$3" ss_port="$4" ss_password="$5"
    run_core_install || exit 1
    local key_pair=$("$xray_binary_path" x25519)
    local private_key=$(echo "$key_pair" | awk '/PrivateKey:/ {print $2}')
    local public_key=$(echo "$key_pair" | awk '/Password:/ {print $2}')
    local vless_inbound=$(build_vless_inbound "$vless_port" "$vless_uuid" "$vless_domain" "$private_key" "$public_key")
    local ss_inbound=$(build_ss_inbound "$ss_port" "$ss_password")
    write_config "[$vless_inbound, $ss_inbound]"
    if ! restart_xray; then exit 1; fi
    success "双协议安装成功！"
    view_all_info
}

main_menu() {
    while true; do
        draw_menu_header
        echo "1. 安装 Xray (VLESS/SS)"
        echo "2. 更新 Xray"
        echo "3. 卸载 Xray"
        echo "4. 重启 Xray"
        echo "5. 查看日志"
        echo "6. 查看订阅"
        echo "0. 退出"
        draw_divider
        read -p "选项: " choice || true
        case "$choice" in
            1) install_menu ;;
            2) update_xray ;;
            3) uninstall_xray ;;
            4) restart_xray ;;
            5) view_xray_log ;;
            6) view_all_info ;;
            0) exit 0 ;;
            *) error "无效选项" ;;
        esac
        press_any_key_to_continue
    done
}

non_interactive_dispatcher() {
    if [[ $# -eq 0 || "$1" != "install" ]]; then main_menu; return; fi
    shift
    local type="" vless_port="" uuid="" sni="" ss_port="" ss_pass=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --type) type="$2"; shift 2 ;;
            --vless-port) vless_port="$2"; shift 2 ;;
            --uuid) uuid="$2"; shift 2 ;;
            --sni) sni="$2"; shift 2 ;;
            --ss-port) ss_port="$2"; shift 2 ;;
            --ss-pass) ss_pass="$2"; shift 2 ;;
            --quiet) is_quiet=true; shift ;;
            *) shift ;;
        esac
    done
    case "$type" in
        vless)
            [[ -z "$vless_port" ]] && vless_port=443
            [[ -z "$uuid" ]] && uuid=$(cat /proc/sys/kernel/random/uuid)
            [[ -z "$sni" ]] && sni="learn.microsoft.com"
            run_install_vless "$vless_port" "$uuid" "$sni" ;;
        ss)
            [[ -z "$ss_port" ]] && ss_port=8388
            [[ -z "$ss_pass" ]] && ss_pass=$(generate_ss_key)
            run_install_ss "$ss_port" "$ss_pass" ;;
        dual)
            [[ -z "$vless_port" ]] && vless_port=443
            [[ -z "$uuid" ]] && uuid=$(cat /proc/sys/kernel/random/uuid)
            [[ -z "$sni" ]] && sni="learn.microsoft.com"
            [[ -z "$ss_pass" ]] && ss_pass=$(generate_ss_key)
            [[ -z "$ss_port" ]] && ss_port=$((vless_port + 1))
            run_install_dual "$vless_port" "$uuid" "$sni" "$ss_port" "$ss_pass" ;;
    esac
}

main() {
    pre_check
    non_interactive_dispatcher "$@"
}

main "$@"
