#!/bin/bash

# 1. 检查并安装必要依赖 (jq, bc)
if ! command -v jq &> /dev/null || ! command -v bc &> /dev/null; then
    echo "安装必要依赖 (jq/bc)..."
    if [ -n "$(command -v apt)" ]; then
        apt update > /dev/null 2>&1
        apt install -y jq bc > /dev/null 2>&1
    elif [ -n "$(command -v yum)" ]; then
        yum install -y epel-release
        yum install -y jq bc
    fi
fi

# 检查旧文件是否存在
if [ -f "/root/reality.json" ] && [ -f "/root/sing-box" ]; then
    echo "检测到已安装 sing-box。"
    echo "1. 重新安装  2. 更改配置  3. 当前配置  4. 切换版本  5. 卸载"
    read -p "请输入选择 (1-5): " choice
    case $choice in
        1) systemctl stop sing-box; rm /root/reality.json /root/sing-box ;;
        2) # 简化逻辑：重装以更改配置
           systemctl stop sing-box ;;
        3) # 显示当前配置链接并退出
           uuid=$(jq -r '.inbounds[0].users[0].uuid' /root/reality.json)
           sip=$(curl -s https://api.ipify.org)
           port=$(jq -r '.inbounds[0].listen_port' /root/reality.json)
           sni=$(jq -r '.inbounds[0].tls.server_name' /root/reality.json)
           pbk=$(base64 --decode /root/public.key.b64)
           sid=$(jq -r '.inbounds[0].tls.reality.short_id[0]' /root/reality.json)
           echo -e "\n当前链接:\nvless://$uuid@$sip:$port?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$sni&fp=chrome&pbk=$pbk&sid=$sid&type=tcp&headerType=none#Singbox-TCP\n"
           exit 0 ;;
        5) systemctl stop sing-box; systemctl disable sing-box > /dev/null 2>&1
           rm /etc/systemd/system/sing-box.service /root/reality.json /root/sing-box /root/public.key.b64
           echo "卸载完成!"; exit 0 ;;
    esac
fi

# --- 核心功能：域名测速函数 ---
get_best_sni() {
    local domains=("www.salesforce.com" "www.costco.com" "www.bing.com" "learn.microsoft.com" "swdist.apple.com" "www.tesla.com" "www.softbank.jp" "www.homedepot.com" "scholar.google.com" "itunes.apple.com" "www.amazon.com" "dl.google.com" "www.bbc.com" "www.reddit.com" "addons.mozilla.org" "www.yahoo.co.jp" "www.lovelive-anime.jp" "www.mtr.com.hk")
    
    local min_lat=9999
    local best_d=""
    
    echo -e "\n正在测试 17 个候选域名的延迟与抖动 (ping 10次)..."
    echo "------------------------------------------------------"
    printf "%-25s | %-12s | %-10s\n" "域名" "平均延迟" "抖动"
    
    for d in "${domains[@]}"; do
        local res=$(ping -c 10 -q "$d" 2>/dev/null | tail -1)
        if [ -n "$res" ]; then
            local avg=$(echo "$res" | cut -d '/' -f 5)
            local jitter=$(echo "$res" | cut -d '/' -f 7 | cut -d ' ' -f 1)
            printf "%-25s | %-8s ms | %-8s ms\n" "$d" "$avg" "$jitter"
            
            if (( $(echo "$avg < $min_lat" | bc -l) )); then
                min_lat=$avg
                best_d=$d
            fi
        else
            printf "%-25s | %-12s\n" "$d" "超时/失败"
        fi
    done
    echo "------------------------------------------------------"
    # 输出给变量调用，最后一行是结果
    echo "RESULT $best_d $min_lat"
}

# --- 安装流程 ---

# 1. 选择版本
echo ""
read -p "选择安装版本 (1.稳定版 2.测试版, 默认 1): " v_choice
v_choice=${v_choice:-1}
is_pre="false"; [ "$v_choice" -eq 2 ] && is_pre="true"

# 获取下载地址
latest_version_tag=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases" | jq -r "[.[] | select(.prerelease==$is_pre)][0].tag_name")
latest_version=${latest_version_tag#v}
arch=$(uname -m)
case ${arch} in x86_64) arch="amd64" ;; aarch64) arch="arm64" ;; armv7l) arch="armv7" ;; esac
package_name="sing-box-${latest_version}-linux-${arch}"
url="https://github.com/SagerNet/sing-box/releases/download/${latest_version_tag}/${package_name}.tar.gz"

# 2. 下载核心并显示进度条
echo -e "\n\033[36m正在下载 sing-box $latest_version_tag...\033[0m"
curl -# -L -o "/root/${package_name}.tar.gz" "$url"

# 3. 解压并清理
echo "正在安装核心文件..."
tar -xzf "/root/${package_name}.tar.gz" -C /root && mv "/root/${package_name}/sing-box" /root/
rm -r "/root/${package_name}.tar.gz" "/root/${package_name}"
chmod +x /root/sing-box

# 4. 执行测速并获取 IP
sni_data=$(get_best_sni)
best_domain=$(echo "$sni_data" | grep "RESULT" | awk '{print $2}')
best_latency=$(echo "$sni_data" | grep "RESULT" | awk '{print $3}')

auto_ip=$(curl -s https://api.ipify.org || curl -s https://ifconfig.me)

# 5. 交互确认
echo -e "\n自动获取的公网 IP: \033[32m$auto_ip\033[0m"
read -p "确认 IP (直接回车确认，或输入新 IP): " user_ip
server_ip=${user_ip:-$auto_ip}

read -p "输入监听端口 (默认 443): " listen_port
listen_port=${listen_port:-443}

echo -e "\n最优域名推荐: \033[32m$best_domain\033[0m (平均延迟: \033[33m${best_latency}ms\033[0m)"
read -p "确认 SNI (默认使用 $best_domain): " server_name
server_name=${server_name:-$best_domain}

# 6. 生成 REALITY 配置
uuid=$(/root/sing-box generate uuid)
short_id=$(/root/sing-box generate rand --hex 8)
key_pair=$(/root/sing-box generate reality-keypair)
private_key=$(echo "$key_pair" | awk '/PrivateKey/ {print $2}' | tr -d '"')
public_key=$(echo "$key_pair" | awk '/PublicKey/ {print $2}' | tr -d '"')
echo "$public_key" | base64 > /root/public.key.b64

jq -n --arg lp "$listen_port" --arg sn "$server_name" --arg pk "$private_key" --arg sid "$short_id" --arg uuid "$uuid" \
'{
  "log": {"level": "info","timestamp": true},
  "inbounds": [{
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": ($lp | tonumber),
      "sniff": true,
      "sniff_override_destination": true,
      "domain_strategy": "ipv4_only",
      "users": [{"uuid": $uuid,"flow": "xtls-rprx-vision"}],
      "tls": {
        "enabled": true,
        "server_name": $sn,
        "reality": {
          "enabled": true,
          "handshake": {"server": $sn,"server_port": 443},
          "private_key": $pk,
          "short_id": [$sid]
        }
      }
  }],
  "outbounds": [{"type": "direct","tag": "direct"}]
}' > /root/reality.json

# 7. 写入服务并启动
cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
After=network.target nss-lookup.target
[Service]
User=root
WorkingDirectory=/root
ExecStart=/root/sing-box run -c /root/reality.json
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload && systemctl enable sing-box && systemctl restart sing-box

# 8. 完成展示
server_link="vless://$uuid@$server_ip:$listen_port?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$server_name&fp=chrome&pbk=$public_key&sid=$short_id&type=tcp&headerType=none#Singbox-TCP"

echo -e "\n\033[32m✔ 安装并启动成功!\033[0m"
echo -e "已选 SNI: $server_name (${best_latency}ms)"
echo -e "\n节点链接:"
echo -e "\033[33m$server_link\033[0m\n"
