#!/bin/bash

# ==============================================================================
# Xray VLESS-Reality & Shadowsocks 2022 多功能管理脚本
# 版本: Final v3.0.0 (SNI 优选版 / Clash YAML 输出版 + QR码支持)
# 更新日志 (v3.0.0):
# - [修复] Reality 密钥解析兼容新版/旧版 xray x25519 输出
# - [修复] 解决偶发“生成 Reality 密钥对失败”问题
# - [优化] 补全 openssl/wget/ping/ss 等依赖检查与自动安装
# - [新增] 最终配置信息统一导出为 Clash 标准 YAML（英文 key）
# - [新增] 自动生成标准 VLESS/SS 分享链接并在终端打印二维码 (qrencode)
# ==============================================================================

# --- Shell 严格模式 ---
set -euo pipefail

# --- 全局常量 ---
readonly SCRIPT_VERSION="Final v3.0.0"
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

    [[ "$is_quiet" = true ]] && return 0

    while kill -0 "$pid" 2>/dev/null; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        spinstr=$temp${spinstr%"$temp"}
        sleep 0.1
        printf "\r"
    done
    printf "    \r"
}

get_public_ip() {
    local ip=""
    local attempts=0
    local max_attempts=2

    while [[ $attempts -lt $max_attempts ]]; do
        for cmd in "curl -4s --max-time 5" "wget -4qO- --timeout=5"; do
            for url in "https://api.ipify.org" "https://ip.sb" "https://checkip.amazonaws.com"; do
                ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
            done
        done
        ((attempts++))
        [[ $attempts -lt $max_attempts ]] && sleep 1
    done

    # IPv6 fallback
    for cmd in "curl -6s --max-time 5" "wget -6qO- --timeout=5"; do
        for url in "https://api64.ipify.org" "https://ip.sb"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
        done
    done

    return 1
}

# --- 预检查与环境设置 ---
pre_check() {
    [[ "$(id -u)" != 0 ]] && error "错误: 您必须以root用户身份运行此脚本" && exit 1
    if [[ ! -f /etc/debian_version ]]; then
        error "错误: 此脚本仅支持 Debian/Ubuntu 及其衍生系统。"
        exit 1
    fi

    # 新增 qrencode 依赖
    local dependencies=("jq" "curl" "bc" "openssl" "ping" "ss" "wget" "qrencode")
    local missing=()

    for dep in "${dependencies[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            missing+=("$dep")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        info "检测到缺失依赖: ${missing[*]}，正在尝试自动安装..."
        (
            DEBIAN_FRONTEND=noninteractive apt-get update &&
            DEBIAN_FRONTEND=noninteractive apt-get install -y \
                jq curl bc openssl wget ca-certificates iputils-ping iproute2 qrencode
        ) &>/dev/null &
        local install_pid=$!
        spinner "$install_pid"

        if ! wait "$install_pid"; then
            error "依赖自动安装失败。请手动运行: apt update && apt install -y jq curl bc openssl wget ca-certificates iputils-ping iproute2 qrencode"
            exit 1
        fi

        for dep in "${dependencies[@]}"; do
            if ! command -v "$dep" &>/dev/null; then
                error "依赖 ($dep) 自动安装后仍缺失，请手动安装后重试。"
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

# --- SNI 优选功能 ---
get_best_sni() {
    local domains=(
        "www.salesforce.com" "www.costco.com" "www.bing.com"
        "learn.microsoft.com" "swdist.apple.com" "www.tesla.com"
        "www.softbank.jp" "www.homedepot.com" "scholar.google.com"
        "itunes.apple.com" "www.amazon.com" "lacma.org"
        "addons.mozilla.org" "www.yahoo.co.jp"
        "www.lovelive-anime.jp" "www.mtr.com.hk"
    )

    echo -e "\n${cyan}正在对 16 个常用 SNI 域名进行延迟测试 (每域名 Ping 4 次)...${none}" >&2
    echo "------------------------------------------------------" >&2
    printf "%-25s | %-10s | %-10s\n" "域名" "平均延迟" "抖动" >&2

    local min_latency=9999
    local best_domain="learn.microsoft.com"
    local best_jitter=0

    for domain in "${domains[@]}"; do
        local res avg jitter
        res=$(ping -c 4 -W 1 -q "$domain" 2>/dev/null | tail -1 || true)
        if [[ -n "$res" ]]; then
            avg=$(echo "$res" | cut -d '/' -f 5)
            jitter=$(echo "$res" | cut -d '/' -f 7 | cut -d ' ' -f 1)
            [[ -z "$avg" ]] && continue

            printf "%-25s | %-8s ms | %-8s ms\n" "$domain" "$avg" "$jitter" >&2

            if (( $(echo "$avg < $min_latency" | bc -l) )); then
                min_latency="$avg"
                best_domain="$domain"
                best_jitter="$jitter"
            fi
        else
            printf "%-25s | %-10s\n" "$domain" "超时/不可达" >&2
        fi
    done

    echo "------------------------------------------------------" >&2
    echo -e "${green}推荐最佳 SNI: $best_domain${none} (延迟: ${min_latency}ms, 抖动: ${best_jitter}ms)" >&2
    echo "$best_domain"
}

# --- 核心配置生成函数 ---
generate_ss_key() {
    openssl rand -base64 16
}

yaml_escape() {
    local s="${1:-}"
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    printf '%s' "$s"
}

generate_reality_keypair() {
    local -n out_private="$1" out_public="$2"
    local raw_output candidates

    raw_output=$("$xray_binary_path" x25519 2>&1) || {
        error "执行 xray x25519 失败: $raw_output"
        return 1
    }

    out_private=$(echo "$raw_output" | awk -F': *' '{
        k=tolower($1);
        if (k ~ /private[[:space:]]*key/) {gsub(/\r/,"",$2); print $2; exit}
    }')
    out_public=$(echo "$raw_output" | awk -F': *' '{
        k=tolower($1);
        if (k ~ /public[[:space:]]*key/ || k ~ /password/) {gsub(/\r/,"",$2); print $2; exit}
    }')

    # 兜底：无标签时提取前两个疑似 key 字符串
    if [[ -z "$out_private" || -z "$out_public" ]]; then
        candidates=$(echo "$raw_output" | grep -Eo '[A-Za-z0-9+/=_-]{40,}' || true)
        [[ -z "$out_private" ]] && out_private=$(echo "$candidates" | sed -n '1p')
        [[ -z "$out_public" ]] && out_public=$(echo "$candidates" | sed -n '2p')
    fi

    if [[ -z "$out_private" || -z "$out_public" ]]; then
        error "无法解析 Reality 密钥对，xray 输出异常: $raw_output"
        return 1
    fi
}

build_vless_inbound() {
    local port="$1" uuid="$2" domain="$3" private_key="$4" public_key="$5" shortid="20220701"
    jq -n \
        --argjson port "$port" \
        --arg uuid "$uuid" \
        --arg domain "$domain" \
        --arg private_key "$private_key" \
        --arg public_key "$public_key" \
        --arg shortid "$shortid" \
        '{
          "listen": "0.0.0.0",
          "port": $port,
          "protocol": "vless",
          "settings": {
            "clients": [{"id": $uuid, "flow": "xtls-rprx-vision"}],
            "decryption": "none"
          },
          "streamSettings": {
            "network": "tcp",
            "security": "reality",
            "realitySettings": {
              "show": false,
              "dest": ($domain + ":443"),
              "xver": 0,
              "serverNames": [$domain],
              "privateKey": $private_key,
              "publicKey": $public_key,
              "shortIds": [$shortid]
            }
          },
          "sniffing": {
            "enabled": true,
            "destOverride": ["http", "tls", "quic"]
          }
        }'
}

build_ss_inbound() {
    local port="$1" password="$2"
    jq -n \
        --argjson port "$port" \
        --arg password "$password" \
        '{
          "listen": "0.0.0.0",
          "port": $port,
          "protocol": "shadowsocks",
          "settings": {
            "method": "2022-blake3-aes-128-gcm",
            "password": $password
          }
        }'
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
              "settings": {"domainStrategy": "UseIPv4v6"}
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

write_clash_config() {
    local output_file="$1" ip="$2" host="$3" vless_inbound="$4" ss_inbound="$5"
    local -a proxy_names=()

    cat > "$output_file" <<'EOF'
mixed-port: 7890
allow-lan: true
mode: rule
log-level: info
ipv6: true

proxies:
EOF

    if [[ -n "$vless_inbound" ]]; then
        local uuid port domain public_key shortid vless_name
        uuid=$(echo "$vless_inbound" | jq -r '.settings.clients[0].id')
        port=$(echo "$vless_inbound" | jq -r '.port')
        domain=$(echo "$vless_inbound" | jq -r '.streamSettings.realitySettings.serverNames[0]')
        public_key=$(echo "$vless_inbound" | jq -r '.streamSettings.realitySettings.publicKey')
        shortid=$(echo "$vless_inbound" | jq -r '.streamSettings.realitySettings.shortIds[0]')
        vless_name="${host}-vless-reality"

        if [[ -n "$public_key" && "$public_key" != "null" ]]; then
            proxy_names+=("$vless_name")
            cat >> "$output_file" <<EOF
  - name: "$(yaml_escape "$vless_name")"
    type: vless
    server: "$(yaml_escape "$ip")"
    port: $port
    uuid: "$(yaml_escape "$uuid")"
    network: tcp
    udp: true
    tls: true
    servername: "$(yaml_escape "$domain")"
    flow: xtls-rprx-vision
    client-fingerprint: chrome
    reality-opts:
      public-key: "$(yaml_escape "$public_key")"
      short-id: "$(yaml_escape "$shortid")"
EOF
        fi
    fi

    if [[ -n "$ss_inbound" ]]; then
        local ss_port ss_method ss_password ss_name
        ss_port=$(echo "$ss_inbound" | jq -r '.port')
        ss_method=$(echo "$ss_inbound" | jq -r '.settings.method')
        ss_password=$(echo "$ss_inbound" | jq -r '.settings.password')
        ss_name="${host}-ss2022"

        proxy_names+=("$ss_name")
        cat >> "$output_file" <<EOF
  - name: "$(yaml_escape "$ss_name")"
    type: ss
    server: "$(yaml_escape "$ip")"
    port: $ss_port
    cipher: "$(yaml_escape "$ss_method")"
    password: "$(yaml_escape "$ss_password")"
    udp: true
EOF
    fi

    if [[ ${#proxy_names[@]} -eq 0 ]]; then
        rm -f "$output_file"
        return 1
    fi

    {
        cat <<'EOF'
proxy-groups:
  - name: "PROXY"
    type: select
    proxies:
EOF
        for name in "${proxy_names[@]}"; do
            printf '      - "%s"\n' "$(yaml_escape "$name")"
        done
        cat <<'EOF'
      - "DIRECT"

rules:
  - MATCH,PROXY
EOF
    } >> "$output_file"

    chmod 600 "$output_file"
}

execute_official_script() {
    local args="$1"
    local script_content
    local -a arg_array=()

    script_content=$(curl -fsSL "$xray_install_script_url" 2>/dev/null || true)
    if [[ -z "$script_content" || ! "$script_content" =~ install-release ]]; then
        error "下载 Xray 官方安装脚本失败或内容异常！请检查网络连接。"
        return 1
    fi

    if [[ -n "$args" ]]; then
        read -r -a arg_array <<< "$args"
    fi

    (echo "$script_content" | bash -s -- "${arg_array[@]}") &>/dev/null &
    local task_pid=$!
    spinner "$task_pid"

    if ! wait "$task_pid"; then
        return 1
    fi
}

run_core_install() {
    info "正在下载并安装 Xray 核心..."
    if ! execute_official_script "install"; then
        error "Xray 核心安装失败！"
        return 1
    fi

    if [[ ! -x "$xray_binary_path" ]]; then
        error "Xray 安装后未找到可执行文件: $xray_binary_path"
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
    [[ "$port" =~ ^[0-9]+$ ]] && [[ "$port" -ge 1 ]] && [[ "$port" -le 65535 ]]
}

is_port_available() {
    local port="$1"
    is_valid_port "$port" || return 1
    if ss -tlpn 2>/dev/null | grep -q ":$port "; then
        warning "端口 $port 已被占用，建议选择其他端口"
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
        read -p "$(echo -e " -> 请输入 VLESS 端口 (默认: ${cyan}${default_port}${none}): ")" p_port || true
        [[ -z "$p_port" ]] && p_port="$default_port"
        if is_port_available "$p_port"; then
            break
        fi
    done
    info "VLESS 端口将使用: ${cyan}${p_port}${none}"

    read -p "$(echo -e " -> 请输入UUID (留空将自动生成): ")" p_uuid || true
    if [[ -z "$p_uuid" ]]; then
        p_uuid=$(cat /proc/sys/kernel/random/uuid)
        info "已为您生成随机UUID: ${cyan}${p_uuid}${none}"
    fi

    local default_sni="learn.microsoft.com"
    local use_auto_sni=""

    echo ""
    read -p "$(echo -e " -> 是否自动测试并优选最佳 SNI 域名? [Y/n] (默认: ${cyan}Y${none}): ")" use_auto_sni || true
    [[ -z "$use_auto_sni" ]] && use_auto_sni="y"

    if [[ "$use_auto_sni" =~ ^[yY]$ ]]; then
        default_sni=$(get_best_sni)
    fi

    while true; do
        read -p "$(echo -e " -> 请输入SNI域名 (默认: ${cyan}${default_sni}${none}): ")" p_sni || true
        [[ -z "$p_sni" ]] && p_sni="$default_sni"
        if is_valid_domain "$p_sni"; then
            break
        else
            error "域名格式无效，请重新输入。"
        fi
    done
    info "SNI 域名将使用: ${cyan}${p_sni}${none}"
}

prompt_for_ss_config() {
    local -n p_port="$1" p_pass="$2"
    local default_port="${3:-8388}"

    while true; do
        read -p "$(echo -e " -> 请输入 Shadowsocks 端口 (默认: ${cyan}${default_port}${none}): ")" p_port || true
        [[ -z "$p_port" ]] && p_port="$default_port"
        if is_port_available "$p_port"; then
            break
        fi
    done
    info "Shadowsocks 端口将使用: ${cyan}${p_port}${none}"

    read -p "$(echo -e " -> 请输入 Shadowsocks 密钥 (留空将自动生成): ")" p_pass || true
    if [[ -z "$p_pass" ]]; then
        p_pass=$(generate_ss_key)
        info "已为您生成随机密钥: ${cyan}${p_pass}${none}"
    fi
}

# --- 菜单功能函数 ---
draw_divider() {
    printf "%0.s─" {1..48}
    printf "\n"
}

draw_menu_header() {
    clear
    echo -e "${cyan} Xray VLESS-Reality & Shadowsocks-2022 管理脚本${none}"
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
        success "您已安装 VLESS-Reality + Shadowsocks-2022 双协议。"
        info "如需修改，请使用主菜单的\"修改配置\"选项。\n 如需重装，请先\"卸载\"后，再重新\"安装\"。"
        return
    elif [[ -n "$vless_exists" && -z "$ss_exists" ]]; then
        info "检测到您已安装 VLESS-Reality"
        echo -e "${cyan} 请选择下一步操作${none}"
        draw_divider
        printf "  ${green}%-2s${none} %-35s\n" "1." "追加安装 Shadowsocks-2022 (组成双协议)"
        printf "  ${red}%-2s${none} %-35s\n" "2." "覆盖重装 VLESS-Reality"
        draw_divider
        printf "  ${yellow}%-2s${none} %-35s\n" "0." "返回主菜单"
        draw_divider
        local choice=""
        read -p " 请输入选项 [0-2]: " choice || true
        case "$choice" in
            1) add_ss_to_vless ;;
            2) install_vless_only ;;
            0) return ;;
            *) error "无效选项。" ;;
        esac
    elif [[ -z "$vless_exists" && -n "$ss_exists" ]]; then
        info "检测到您已安装 Shadowsocks-2022"
        echo -e "${cyan} 请选择下一步操作${none}"
        draw_divider
        printf "  ${green}%-2s${none} %-35s\n" "1." "追加安装 VLESS-Reality (组成双协议)"
        printf "  ${red}%-2s${none} %-35s\n" "2." "覆盖重装 Shadowsocks-2022"
        draw_divider
        printf "  ${yellow}%-2s${none} %-35s\n" "0." "返回主菜单"
        draw_divider
        local choice=""
        read -p " 请输入选项 [0-2]: " choice || true
        case "$choice" in
            1) add_vless_to_ss ;;
            2) install_ss_only ;;
            0) return ;;
            *) error "无效选项。" ;;
        esac
    else
        clean_install_menu
    fi
}

clean_install_menu() {
    draw_menu_header
    echo -e "${cyan} 请选择要安装的协议类型${none}"
    draw_divider
    printf "  ${green}%-2s${none} %-35s\n" "1." "仅 VLESS-Reality"
    printf "  ${cyan}%-2s${none} %-35s\n" "2." "仅 Shadowsocks-2022"
    printf "  ${yellow}%-2s${none} %-35s\n" "3." "VLESS-Reality + Shadowsocks-2022 (双协议)"
    draw_divider
    printf "  ${magenta}%-2s${none} %-35s\n" "0." "返回主菜单"
    draw_divider
    local choice=""
    read -p " 请输入选项 [0-3]: " choice || true
    case "$choice" in
        1) install_vless_only ;;
        2) install_ss_only ;;
        3) install_dual ;;
        0) return ;;
        *) error "无效选项。" ;;
    esac
}

add_ss_to_vless() {
    info "开始追加安装 Shadowsocks-2022..."
    if [[ -z "$(get_public_ip)" ]]; then
        error "无法获取公网 IP 地址，操作中止。请检查您的网络连接。"
        return 1
    fi

    local vless_inbound vless_port default_ss_port ss_port ss_password ss_inbound
    vless_inbound=$(jq '.inbounds[] | select(.protocol == "vless")' "$xray_config_path")
    vless_port=$(echo "$vless_inbound" | jq -r '.port')
    default_ss_port=$([[ "$vless_port" == "443" ]] && echo "8388" || echo "$((vless_port + 1))")

    prompt_for_ss_config ss_port ss_password "$default_ss_port"

    ss_inbound=$(build_ss_inbound "$ss_port" "$ss_password")
    write_config "[$vless_inbound, $ss_inbound]"

    if ! restart_xray; then
        return 1
    fi

    success "追加安装成功！"
    view_all_info
}

add_vless_to_ss() {
    info "开始追加安装 VLESS-Reality..."
    if [[ -z "$(get_public_ip)" ]]; then
        error "无法获取公网 IP 地址，操作中止。请检查您的网络连接。"
        return 1
    fi

    local ss_inbound ss_port default_vless_port vless_port vless_uuid vless_domain
    local private_key public_key vless_inbound
    ss_inbound=$(jq '.inbounds[] | select(.protocol == "shadowsocks")' "$xray_config_path")
    ss_port=$(echo "$ss_inbound" | jq -r '.port')
    default_vless_port=$([[ "$ss_port" == "8388" ]] && echo "443" || echo "$((ss_port - 1))")

    prompt_for_vless_config vless_port vless_uuid vless_domain "$default_vless_port"

    info "正在生成 Reality 密钥对..."
    if ! generate_reality_keypair private_key public_key; then
        error "生成 Reality 密钥对失败！请检查 Xray 核心是否正常，或尝试更新后重试。"
        return 1
    fi

    vless_inbound=$(build_vless_inbound "$vless_port" "$vless_uuid" "$vless_domain" "$private_key" "$public_key")
    write_config "[$vless_inbound, $ss_inbound]"

    if ! restart_xray; then
        return 1
    fi

    success "追加安装成功！"
    view_all_info
}

install_vless_only() {
    info "开始配置 VLESS-Reality..."
    local port uuid domain
    prompt_for_vless_config port uuid domain
    run_install_vless "$port" "$uuid" "$domain"
}

install_ss_only() {
    info "开始配置 Shadowsocks-2022..."
    local port password
    prompt_for_ss_config port password
    run_install_ss "$port" "$password"
}

install_dual() {
    info "开始配置双协议 (VLESS-Reality + Shadowsocks-2022)..."
    local vless_port vless_uuid vless_domain ss_port ss_password
    prompt_for_vless_config vless_port vless_uuid vless_domain

    local default_ss_port
    if [[ "$vless_port" == "443" ]]; then
        default_ss_port=8388
    else
        default_ss_port=$((vless_port + 1))
    fi

    prompt_for_ss_config ss_port ss_password "$default_ss_port"
    run_install_dual "$vless_port" "$vless_uuid" "$vless_domain" "$ss_port" "$ss_password"
}

update_xray() {
    if [[ ! -f "$xray_binary_path" ]]; then
        error "错误: Xray 未安装。"
        return
    fi

    info "正在检查最新版本..."
    local current_version latest_version
    current_version=$("$xray_binary_path" version | head -n 1 | awk '{print $2}')
    latest_version=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r '.tag_name' | sed 's/v//' || echo "")

    if [[ -z "$latest_version" ]]; then
        error "获取最新版本号失败，请检查网络或稍后重试。"
        return
    fi

    info "当前版本: ${cyan}${current_version}${none}，最新版本: ${cyan}${latest_version}${none}"

    if [[ "$current_version" == "$latest_version" ]]; then
        success "您的 Xray 已是最新版本。"
        return
    fi

    info "发现新版本，开始更新..."
    run_core_install
    if ! restart_xray; then
        return 1
    fi
    success "Xray 更新成功！"
}

uninstall_xray() {
    if [[ ! -f "$xray_binary_path" ]]; then
        error "错误: Xray 未安装。"
        return
    fi

    read -p "$(echo -e "${yellow}您确定要卸载 Xray 吗？这将删除所有配置！[Y/n]: ${none}")" confirm || true
    if [[ "$confirm" =~ ^[nN]$ ]]; then
        info "操作已取消。"
        return
    fi

    info "正在卸载 Xray..."
    if ! execute_official_script "remove --purge"; then
        error "Xray 卸载失败！"
        return 1
    fi

    rm -f ~/xray_subscription_info.txt ~/clash_config.yaml
    success "Xray 已成功卸载。"
}

modify_config_menu() {
    if [[ ! -f "$xray_config_path" ]]; then
        error "错误: Xray 未安装。"
        return
    fi

    local vless_exists="" ss_exists=""
    vless_exists=$(jq '.inbounds[] | select(.protocol == "vless")' "$xray_config_path" 2>/dev/null || true)
    ss_exists=$(jq '.inbounds[] | select(.protocol == "shadowsocks")' "$xray_config_path" 2>/dev/null || true)

    if [[ -n "$vless_exists" && -n "$ss_exists" ]]; then
        draw_menu_header
        echo -e "${cyan} 请选择要修改的协议配置${none}"
        draw_divider
        printf "  ${green}%-2s${none} %-35s\n" "1." "VLESS-Reality"
        printf "  ${cyan}%-2s${none} %-35s\n" "2." "Shadowsocks-2022"
        draw_divider
        printf "  ${yellow}%-2s${none} %-35s\n" "0." "返回主菜单"
        draw_divider
        local choice=""
        read -p " 请输入选项 [0-2]: " choice || true
        case "$choice" in
            1) modify_vless_config ;;
            2) modify_ss_config ;;
            0) return ;;
            *) error "无效选项。" ;;
        esac
    elif [[ -n "$vless_exists" ]]; then
        modify_vless_config
    elif [[ -n "$ss_exists" ]]; then
        modify_ss_config
    else
        error "未找到可修改的协议配置。"
    fi
}

modify_vless_config() {
    info "开始修改 VLESS-Reality 配置..."
    local vless_inbound current_port current_uuid current_domain private_key public_key
    local port uuid domain new_vless_inbound ss_inbound new_inbounds

    vless_inbound=$(jq '.inbounds[] | select(.protocol == "vless")' "$xray_config_path")
    current_port=$(echo "$vless_inbound" | jq -r '.port')
    current_uuid=$(echo "$vless_inbound" | jq -r '.settings.clients[0].id')
    current_domain=$(echo "$vless_inbound" | jq -r '.streamSettings.realitySettings.serverNames[0]')
    private_key=$(echo "$vless_inbound" | jq -r '.streamSettings.realitySettings.privateKey')
    public_key=$(echo "$vless_inbound" | jq -r '.streamSettings.realitySettings.publicKey')

    while true; do
        read -p "$(echo -e " -> 新端口 (当前: ${cyan}${current_port}${none}, 留空不改): ")" port || true
        [[ -z "$port" ]] && port="$current_port"
        if is_port_available "$port" || [[ "$port" == "$current_port" ]]; then
            break
        fi
    done

    read -p "$(echo -e " -> 新UUID (当前: ${cyan}${current_uuid}${none}, 留空不改): ")" uuid || true
    [[ -z "$uuid" ]] && uuid="$current_uuid"

    local default_sni="$current_domain"
    local use_auto_sni=""
    read -p "$(echo -e " -> 是否运行 SNI 测速优选? [y/N] (默认: ${cyan}N${none}): ")" use_auto_sni || true
    if [[ "$use_auto_sni" =~ ^[yY]$ ]]; then
        default_sni=$(get_best_sni)
    fi

    while true; do
        read -p "$(echo -e " -> 新SNI域名 (当前/优选: ${cyan}${default_sni}${none}, 留空不改): ")" domain || true
        [[ -z "$domain" ]] && domain="$default_sni"
        if is_valid_domain "$domain"; then
            break
        else
            error "域名格式无效，请重新输入。"
        fi
    done

    new_vless_inbound=$(build_vless_inbound "$port" "$uuid" "$domain" "$private_key" "$public_key")
    ss_inbound=$(jq '.inbounds[] | select(.protocol == "shadowsocks")' "$xray_config_path" 2>/dev/null || true)

    new_inbounds="[$new_vless_inbound]"
    [[ -n "$ss_inbound" ]] && new_inbounds="[$new_vless_inbound, $ss_inbound]"

    write_config "$new_inbounds"
    if ! restart_xray; then
        return 1
    fi

    success "配置修改成功！"
    view_all_info
}

modify_ss_config() {
    info "开始修改 Shadowsocks-2022 配置..."
    local ss_inbound current_port current_password port password new_ss_inbound vless_inbound new_inbounds

    ss_inbound=$(jq '.inbounds[] | select(.protocol == "shadowsocks")' "$xray_config_path")
    current_port=$(echo "$ss_inbound" | jq -r '.port')
    current_password=$(echo "$ss_inbound" | jq -r '.settings.password')

    while true; do
        read -p "$(echo -e " -> 新端口 (当前: ${cyan}${current_port}${none}, 留空不改): ")" port || true
        [[ -z "$port" ]] && port="$current_port"
        if is_port_available "$port" || [[ "$port" == "$current_port" ]]; then
            break
        fi
    done

    read -p "$(echo -e " -> 新密钥 (当前: ${cyan}${current_password}${none}, 留空不改): ")" password || true
    [[ -z "$password" ]] && password="$current_password"

    new_ss_inbound=$(build_ss_inbound "$port" "$password")
    vless_inbound=$(jq '.inbounds[] | select(.protocol == "vless")' "$xray_config_path" 2>/dev/null || true)

    new_inbounds="[$new_ss_inbound]"
    [[ -n "$vless_inbound" ]] && new_inbounds="[$vless_inbound, $new_ss_inbound]"

    write_config "$new_inbounds"
    if ! restart_xray; then
        return 1
    fi

    success "配置修改成功！"
    view_all_info
}

restart_xray() {
    if [[ ! -f "$xray_binary_path" ]]; then
        error "错误: Xray 未安装。"
        return 1
    fi

    info "正在重启 Xray 服务..."
    if ! systemctl restart xray; then
        error "尝试重启 Xray 服务失败！"
        echo -e "\n${yellow}错误详情:${none}"
        systemctl status xray --no-pager -l | tail -5
        return 1
    fi

    sleep 2
    if systemctl is-active --quiet xray; then
        success "Xray 服务已成功重启！"
    else
        error "服务启动失败，详细信息:"
        systemctl status xray --no-pager -l | tail -5
        return 1
    fi
}

view_xray_log() {
    if [[ ! -f "$xray_binary_path" ]]; then
        error "错误: Xray 未安装。"
        return
    fi
    info "正在显示 Xray 实时日志... 按 Ctrl+C 退出。"
    journalctl -u xray -f --no-pager
}

# 统一输出 Clash 标准 YAML 及其分享链接/二维码
view_all_info() {
    if [[ ! -f "$xray_config_path" ]]; then
        [[ "$is_quiet" = true ]] && return
        error "Error: config file not found."
        return
    fi

    local ip host clash_output_file vless_inbound ss_inbound
    ip=$(get_public_ip || true)
    if [[ -z "$ip" ]]; then
        [[ "$is_quiet" = false ]] && error "Error: unable to get public IP."
        return 1
    fi

    host=$(hostname)
    clash_output_file="${HOME}/clash_config.yaml"
    vless_inbound=$(jq '.inbounds[] | select(.protocol == "vless")' "$xray_config_path" 2>/dev/null || true)
    ss_inbound=$(jq '.inbounds[] | select(.protocol == "shadowsocks")' "$xray_config_path" 2>/dev/null || true)

    if ! write_clash_config "$clash_output_file" "$ip" "$host" "$vless_inbound" "$ss_inbound"; then
        [[ "$is_quiet" = false ]] && info "No available inbound found."
        return 0
    fi

    if [[ "$is_quiet" = true ]]; then
        cat "$clash_output_file"
        return 0
    fi

    clear
    echo -e "${cyan} Clash Configuration (YAML)${none}"
    draw_divider
    printf " Host: %s\n" "$host"
    printf " Server IP: %s\n" "$ip"
    printf " Output File: %s\n" "$clash_output_file"
    draw_divider
    success "Clash YAML generated successfully."
    echo ""
    cat "$clash_output_file"
    draw_divider

    # 输出标准分享链接及二维码
    echo -e "\n${cyan} 分享链接与二维码 (Share Links & QR Code)${none}"
    draw_divider

    local links_array=()

    if [[ -n "$vless_inbound" ]]; then
        local uuid port domain public_key shortid display_ip link_name_raw link_name_encoded vless_url
        uuid=$(echo "$vless_inbound" | jq -r '.settings.clients[0].id')
        port=$(echo "$vless_inbound" | jq -r '.port')
        domain=$(echo "$vless_inbound" | jq -r '.streamSettings.realitySettings.serverNames[0]')
        public_key=$(echo "$vless_inbound" | jq -r '.streamSettings.realitySettings.publicKey')
        shortid=$(echo "$vless_inbound" | jq -r '.streamSettings.realitySettings.shortIds[0]')

        if [[ -n "$public_key" && "$public_key" != "null" ]]; then
            display_ip=$ip && [[ $ip =~ ":" ]] && display_ip="[$ip]"
            link_name_raw="$host X-reality"
            link_name_encoded=$(echo "$link_name_raw" | sed 's/ /%20/g')
            vless_url="vless://${uuid}@${display_ip}:${port}?flow=xtls-rprx-vision&encryption=none&type=tcp&security=reality&sni=${domain}&fp=chrome&pbk=${public_key}&sid=${shortid}#${link_name_encoded}"
            links_array+=("$vless_url")
        fi
    fi

    if [[ -n "$ss_inbound" ]]; then
        local ss_port ss_method ss_password ss_name user_info_base64 ss_url
        ss_port=$(echo "$ss_inbound" | jq -r '.port')
        ss_method=$(echo "$ss_inbound" | jq -r '.settings.method')
        ss_password=$(echo "$ss_inbound" | jq -r '.settings.password')
        ss_name="$host X-ss2022"
        user_info_base64=$(echo -n "${ss_method}:${ss_password}" | base64 -w 0)
        ss_url="ss://${user_info_base64}@${ip}:${ss_port}#$(echo "$ss_name" | sed 's/ /%20/g')"
        links_array+=("$ss_url")
    fi

    for link in "${links_array[@]}"; do
        echo -e "${green}${link}${none}\n"
        # 终端打印二维码
        qrencode -t UTF8 "$link"
        echo ""
        draw_divider
    done
}

# --- 核心安装逻辑函数 ---
run_install_vless() {
    local port="$1" uuid="$2" domain="$3"

    if [[ -z "$(get_public_ip)" ]]; then
        error "无法获取公网 IP 地址，安装中止。请检查您的网络连接。"
        exit 1
    fi

    run_core_install || exit 1

    info "正在生成 Reality 密钥对..."
    local private_key public_key vless_inbound
    if ! generate_reality_keypair private_key public_key; then
        error "生成 Reality 密钥对失败！请检查 Xray 核心是否正常，或尝试更新后重试。"
        exit 1
    fi

    vless_inbound=$(build_vless_inbound "$port" "$uuid" "$domain" "$private_key" "$public_key")
    write_config "[$vless_inbound]"

    if ! restart_xray; then
        exit 1
    fi

    success "VLESS-Reality 安装成功！"
    view_all_info
}

run_install_ss() {
    local port="$1" password="$2"

    if [[ -z "$(get_public_ip)" ]]; then
        error "无法获取公网 IP 地址，安装中止。请检查您的网络连接。"
        exit 1
    fi

    run_core_install || exit 1

    local ss_inbound
    ss_inbound=$(build_ss_inbound "$port" "$password")
    write_config "[$ss_inbound]"

    if ! restart_xray; then
        exit 1
    fi

    success "Shadowsocks-2022 安装成功！"
    view_all_info
}

run_install_dual() {
    local vless_port="$1" vless_uuid="$2" vless_domain="$3" ss_port="$4" ss_password="$5"

    if [[ -z "$(get_public_ip)" ]]; then
        error "无法获取公网 IP 地址，安装中止。请检查您的网络连接。"
        exit 1
    fi

    run_core_install || exit 1

    info "正在生成 Reality 密钥对..."
    local private_key public_key vless_inbound ss_inbound
    if ! generate_reality_keypair private_key public_key; then
        error "生成 Reality 密钥对失败！请检查 Xray 核心是否正常，或尝试更新后重试。"
        exit 1
    fi

    vless_inbound=$(build_vless_inbound "$vless_port" "$vless_uuid" "$vless_domain" "$private_key" "$public_key")
    ss_inbound=$(build_ss_inbound "$ss_port" "$ss_password")
    write_config "[$vless_inbound, $ss_inbound]"

    if ! restart_xray; then
        exit 1
    fi

    success "双协议安装成功！"
    view_all_info
}

# --- 主菜单与脚本入口 ---
main_menu() {
    while true; do
        draw_menu_header
        printf "  ${green}%-2s${none} %-35s\n" "1." "安装 Xray (VLESS/Shadowsocks)"
        printf "  ${cyan}%-2s${none} %-35s\n" "2." "更新 Xray"
        printf "  ${red}%-2s${none} %-35s\n" "3." "卸载 Xray"
        draw_divider
        printf "  ${yellow}%-2s${none} %-35s\n" "4." "修改配置"
        printf "  ${cyan}%-2s${none} %-35s\n" "5." "重启 Xray"
        printf "  ${magenta}%-2s${none} %-35s\n" "6." "查看 Xray 日志"
        printf "  ${green}%-2s${none} %-35s\n" "7." "查看配置与二维码"
        draw_divider
        printf "  ${yellow}%-2s${none} %-35s\n" "0." "退出脚本"
        draw_divider

        local choice=""
        read -p " 请输入选项 [0-7]: " choice || true

        local needs_pause=true
        case "$choice" in
            1) install_menu ;;
            2) update_xray ;;
            3) uninstall_xray ;;
            4) modify_config_menu ;;
            5) restart_xray ;;
            6) view_xray_log; needs_pause=false ;;
            7) view_all_info ;;
            0) success "感谢使用！"; exit 0 ;;
            *) error "无效选项。请输入0到7之间的数字。" ;;
        esac

        if [[ "$needs_pause" = true ]]; then
            press_any_key_to_continue
        fi
    done
}

# --- 非交互式安装逻辑 ---
non_interactive_usage() {
    cat <<EOF

非交互式安装用法:
  ./$(basename "$0") install --type <vless|ss|dual> [选项...]

  通用选项:
    --type <type>      安装类型 (必须: vless, ss, dual)
    --quiet            静默模式, 成功后仅输出 Clash YAML 到 stdout

  VLESS 选项:
    --vless-port <p>   VLESS 端口 (默认: 443)
    --uuid <uuid>      UUID (默认: 随机生成)
    --sni <domain>     SNI 域名 (默认: learn.microsoft.com)

  Shadowsocks 选项:
    --ss-port <p>      Shadowsocks 端口 (默认: 8388)
    --ss-pass <pass>   Shadowsocks 密码 (默认: 随机生成)

  示例:
    # 安装 VLESS (使用默认值)
    ./$(basename "$0") install --type vless

    # 安静地安装双协议并将 Clash YAML 保存到文件
    ./$(basename "$0") install --type dual --vless-port 2053 --uuid 'your-uuid-here' --quiet > clash_config.yaml
EOF
}

non_interactive_dispatcher() {
    if [[ $# -eq 0 || "$1" != "install" ]]; then
        main_menu
        return
    fi
    shift

    local type="" vless_port="" uuid="" sni="" ss_port="" ss_pass=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --type|--vless-port|--uuid|--sni|--ss-port|--ss-pass)
                if [[ $# -lt 2 ]]; then
                    error "参数 $1 缺少值。"
                    non_interactive_usage
                    exit 1
                fi
                case "$1" in
                    --type) type="$2" ;;
                    --vless-port) vless_port="$2" ;;
                    --uuid) uuid="$2" ;;
                    --sni) sni="$2" ;;
                    --ss-port) ss_port="$2" ;;
                    --ss-pass) ss_pass="$2" ;;
                esac
                shift 2
                ;;
            --quiet)
                is_quiet=true
                shift
                ;;
            *)
                error "未知参数: $1"
                non_interactive_usage
                exit 1
                ;;
        esac
    done

    case "$type" in
        vless)
            [[ -z "$vless_port" ]] && vless_port=443
            [[ -z "$uuid" ]] && uuid=$(cat /proc/sys/kernel/random/uuid)
            [[ -z "$sni" ]] && sni="learn.microsoft.com"
            if ! is_valid_port "$vless_port" || ! is_valid_domain "$sni"; then
                error "VLESS 参数无效。请检查端口或SNI域名。"
                non_interactive_usage
                exit 1
            fi
            info "开始非交互式安装 VLESS..."
            run_install_vless "$vless_port" "$uuid" "$sni"
            ;;
        ss)
            [[ -z "$ss_port" ]] && ss_port=8388
            [[ -z "$ss_pass" ]] && ss_pass=$(generate_ss_key)
            if ! is_valid_port "$ss_port"; then
                error "Shadowsocks 参数无效。请检查端口。"
                non_interactive_usage
                exit 1
            fi
            info "开始非交互式安装 Shadowsocks..."
            run_install_ss "$ss_port" "$ss_pass"
            ;;
        dual)
            [[ -z "$vless_port" ]] && vless_port=443
            [[ -z "$uuid" ]] && uuid=$(cat /proc/sys/kernel/random/uuid)
            [[ -z "$sni" ]] && sni="learn.microsoft.com"
            [[ -z "$ss_pass" ]] && ss_pass=$(generate_ss_key)
            if [[ -z "$ss_port" ]]; then
                if [[ "$vless_port" == "443" ]]; then
                    ss_port=8388
                else
                    ss_port=$((vless_port + 1))
                fi
            fi
            if ! is_valid_port "$vless_port" || ! is_valid_domain "$sni" || ! is_valid_port "$ss_port"; then
                error "双协议参数无效。请检查端口或SNI域名。"
                non_interactive_usage
                exit 1
            fi
            info "开始非交互式安装双协议..."
            run_install_dual "$vless_port" "$uuid" "$sni" "$ss_port" "$ss_pass"
            ;;
        *)
            error "必须通过 --type 指定安装类型 (vless|ss|dual)"
            non_interactive_usage
            exit 1
            ;;
    esac
}

# --- 脚本主入口 ---
main() {
    pre_check
    non_interactive_dispatcher "$@"
}

main "$@"
