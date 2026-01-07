#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Xray VLESS Reality 管理脚本（Debian / Ubuntu / Alpine 完整兼容版）
# SNI 优选逻辑：完全保留原始实现（未简化）
# ==============================================================================

SCRIPT_VERSION="v2.9.x-full-alpine-compatible"

XRAY_BIN="/usr/local/bin/xray"
XRAY_CONF="/usr/local/etc/xray/config.json"
INSTALL_SCRIPT="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

OS_TYPE="unknown"

# ====================== OS 检测 ======================
detect_os() {
    if [[ -f /etc/alpine-release ]]; then
        OS_TYPE="alpine"
    elif [[ -f /etc/debian_version ]]; then
        OS_TYPE="debian"
    else
        echo -e "${RED}不支持的系统${NC}"
        exit 1
    fi
}

# ====================== 依赖安装 ======================
install_deps() {
    if [[ "$OS_TYPE" == "debian" ]]; then
        apt-get update
        apt-get install -y curl jq bc iputils-ping
    else
        apk update
        apk add curl jq bc iputils bash
    fi
}

# ====================== OpenRC 服务 ======================
install_openrc_service() {
cat >/etc/init.d/xray <<'EOF'
#!/sbin/openrc-run
name="xray"
command="/usr/local/bin/xray"
command_args="run -config /usr/local/etc/xray/config.json"
command_background="yes"
pidfile="/run/xray.pid"
depend() { need net; }
EOF
chmod +x /etc/init.d/xray
rc-update add xray default
}

service_restart() {
    if [[ "$OS_TYPE" == "debian" ]]; then
        systemctl restart xray
    else
        rc-service xray restart
    fi
}

# ====================== 安装 Xray ======================
install_xray() {
    curl -Ls "$INSTALL_SCRIPT" | bash -s -- install
    [[ "$OS_TYPE" == "alpine" ]] && install_openrc_service
}

# ====================== 原始 SNI 优选逻辑（完整保留） ======================
get_best_sni() {
    local domains=(
        "www.salesforce.com"
        "www.costco.com"
        "www.bing.com"
        "learn.microsoft.com"
        "swdist.apple.com"
        "www.tesla.com"
        "www.softbank.jp"
        "www.homedepot.com"
        "scholar.google.com"
        "itunes.apple.com"
        "www.amazon.com"
        "dl.google.com"
        "addons.mozilla.org"
        "www.yahoo.co.jp"
        "www.lovelive-anime.jp"
        "www.mtr.com.hk"
    )

    local best_domain="learn.microsoft.com"
    local best_score="999999"

    echo -e "${YELLOW}正在进行 SNI 延迟 / 抖动测试…${NC}" >&2
    printf "%-28s %8s %8s %10s\n" "Domain" "Avg" "Mdev" "Score" >&2

    for domain in "${domains[@]}"; do
        result=$(ping -c 4 -W 1 -q "$domain" 2>/dev/null | tail -1 || true)
        [[ -z "$result" ]] && continue

        avg=$(echo "$result" | awk -F'/' '{print $5}')
        mdev=$(echo "$result" | awk -F'/' '{print $7}')

        [[ -z "$avg" || -z "$mdev" ]] && continue

        score=$(echo "$avg + ($mdev * 2)" | bc)

        printf "%-28s %8s %8s %10s\n" "$domain" "$avg" "$mdev" "$score" >&2

        if (( $(echo "$score < $best_score" | bc -l) )); then
            best_score="$score"
            best_domain="$domain"
        fi
    done

    echo -e "${GREEN}已选择最佳 SNI：$best_domain${NC}" >&2
    echo "$best_domain"
}

# ====================== VLESS Reality 安装 ======================
install_vless_reality() {
    install_xray

    local uuid
    uuid=$(cat /proc/sys/kernel/random/uuid)

    local sni
    sni=$(get_best_sni)

    echo -e "${YELLOW}生成 Reality 密钥…${NC}"
    keypair=$($XRAY_BIN x25519)
    private_key=$(echo "$keypair" | awk '/PrivateKey/ {print $2}')
    public_key=$(echo "$keypair" | awk '/Password/ {print $2}')

    mkdir -p "$(dirname "$XRAY_CONF")"

    jq -n \
        --arg uuid "$uuid" \
        --arg sni "$sni" \
        --arg priv "$private_key" \
        --arg pub "$public_key" \
    '{
      "inbounds":[{
        "port":443,
        "protocol":"vless",
        "settings":{
          "clients":[{"id":$uuid,"flow":"xtls-rprx-vision"}],
          "decryption":"none"
        },
        "streamSettings":{
          "network":"tcp",
          "security":"reality",
          "realitySettings":{
            "dest":($sni + ":443"),
            "serverNames":[$sni],
            "privateKey":$priv,
            "publicKey":$pub,
            "shortIds":[""]
          }
        }
      }],
      "outbounds":[{"protocol":"freedom"}]
    }' > "$XRAY_CONF"

    service_restart

    echo -e "${GREEN}VLESS Reality 安装完成${NC}"
}

# ====================== 菜单 ======================
menu() {
    while true; do
        clear
        echo "Xray 管理脚本 (${SCRIPT_VERSION})"
        echo "1) 安装 VLESS Reality"
        echo "2) 重启 Xray"
        echo "0) 退出"
        read -rp "选择: " opt
        case "$opt" in
            1) install_vless_reality ;;
            2) service_restart ;;
            0) exit 0 ;;
        esac
        read -rp "回车继续..."
    done
}

# ====================== 主入口 ======================
main() {
    [[ $EUID -ne 0 ]] && echo "请使用 root 运行" && exit 1
    detect_os
    install_deps
    menu
}

main "$@"
