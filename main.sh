#!/bin/bash

# 检查依赖
if ! command -v jq &> /dev/null || ! command -v bc &> /dev/null; then
    echo "安装必要依赖 (jq/bc)..."
    if [ -n "$(command -v apt)" ]; then
        apt update > /dev/null 2>&1
        apt install -y jq bc > /dev/null 2>&1
    elif [ -n "$(command -v yum)" ]; then
        yum install -y epel-release
        yum install -y jq bc
    else
        echo "无法安装依赖，请手动安装 jq 和 bc 后重新运行."
        exit 1
    fi
fi

# 功能函数：域名测速选优（考虑延迟与抖动权重）
get_best_sni() {
    local domains=(
        "www.salesforce.com" "www.costco.com" "www.bing.com" 
        "learn.microsoft.com" "swdist.apple.com" "www.tesla.com" 
        "www.softbank.jp" "www.homedepot.com" "scholar.google.com" 
        "itunes.apple.com" "www.amazon.com" "dl.google.com" 
        "cdn.discordapp.com" "addons.mozilla.org" "www.yahoo.co.jp" 
        "www.lovelive-anime.jp" "www.mtr.com.hk"
    )
    
    echo "正在对域名进行 10 次 Ping 测试，正在计算综合稳定性评分..."
    echo "评分标准: 延迟 + 2×抖动 (分值越低越稳)"
    echo "----------------------------------------------------------------------"
    printf "%-25s | %-10s | %-10s | %-8s\n" "域名" "平均延迟" "抖动(mdev)" "质量评分"
    
    local min_score=99999
    local best_domain=""
    local best_avg=0
    local best_jitter=0
    local best_jitter_pct=0

    for domain in "${domains[@]}"; do
        local res=$(ping -c 10 -q "$domain" 2>/dev/null | tail -1)
        if [ -n "$res" ]; then
            # 提取 avg(5) 和 mdev(7)
            local avg=$(echo "$res" | cut -d '/' -f 5)
            local jitter=$(echo "$res" | cut -d '/' -f 7 | cut -d ' ' -f 1)
            
            # 计算抖动百分比 (jitter/avg * 100)
            local jitter_pct=$(echo "scale=1; ($jitter / $avg) * 100" | bc -l)
            # 计算综合评分 (权重: 延迟+2倍抖动)
            local score=$(echo "scale=2; $avg + ($jitter * 2)" | bc -l)
            
            printf "%-25s | %-8s ms | %-8s ms | %-8s\n" "$domain" "$avg" "$jitter" "$score"
            
            if (( $(echo "$score < $min_score" | bc -l) )); then
                min_score=$score
                best_domain=$domain
                best_avg=$avg
                best_jitter=$jitter
                best_jitter_pct=$jitter_pct
            fi
        else
            printf "%-25s | %-10s\n" "$domain" "连接超时"
        fi
    done
    echo "----------------------------------------------------------------------"
    # 将结果通过标准输出传递给外部变量，最后一行用特殊标识符包裹
    echo "RESULT_DATA|${best_domain}|${best_avg}|${best_jitter_pct}%"
}

# 检查文件是否存在
if [ -f "/root/reality.json" ] && [ -f "/root/sing-box" ]; then
    echo "1. 重新安装  2. 更改配置  3. 当前配置  4. 切换版本  5. 卸载"
    read -p "选择 (1-5): " choice
    case $choice in
        1) systemctl stop sing-box; rm /root/reality.json /root/sing-box ;;
        5) systemctl stop sing-box; rm /etc/systemd/system/sing-box.service /root/reality.json /root/sing-box /root/public.key.b64; echo "卸载完成"; exit 0 ;;
        *) echo "仅演示安装逻辑，其他选项已略..." ;;
    esac
fi

# --- 安装/重装流程 ---

# 1. 选择版本
read -p "选择版本 (1.稳定版 2.测试版, 默认1): " v_choice
v_choice=${v_choice:-1}
tag_type="false"; [ "$v_choice" -eq 2 ] && tag_type="true"
latest_version_tag=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases" | jq -r "[.[] | select(.prerelease==$tag_type)][0].tag_name")
latest_version=${latest_version_tag#v}

# 2. 下载与架构检测
arch=$(uname -m)
case ${arch} in x86_64) arch="amd64" ;; aarch64) arch="arm64" ;; armv7l) arch="armv7" ;; esac
package_name="sing-box-${latest_version}-linux-${arch}"
url="https://github.com/SagerNet/sing-box/releases/download/${latest_version_tag}/${package_name}.tar.gz"
curl -sLo "/root/${package_name}.tar.gz" "$url"
tar -xzf "/root/${package_name}.tar.gz" -C /root && mv "/root/${package_name}/sing-box" /root/
rm -r "/root/${package_name}.tar.gz" "/root/${package_name}"
chmod +x /root/sing-box

# 3. 域名测速选优并捕获数据
sni_output=$(get_best_sni)
best_info=$(echo "$sni_output" | grep "RESULT_DATA|")
best_domain=$(echo "$best_info" | cut -d'|' -f2)
best_avg=$(echo "$best_info" | cut -d'|' -f3)
best_jitter_pct=$(echo "$best_info" | cut -d'|' -f4)

# 4. 自动获取 IP
auto_ip=$(curl -s https://api.ipify.org || curl -s https://ifconfig.me)
echo -e "\n自动获取的公网 IP: \033[32m$auto_ip\033[0m"
read -p "确认使用此 IP (回车确认，或输入新 IP): " user_ip
server_ip=${user_ip:-$auto_ip}

# 5. 配置参数 (包含你要求的延迟和抖动百分比显示)
read -p "输入端口 (默认 443): " listen_port
listen_port=${listen_port:-443}
read -p "确认 SNI (默认使用最优 $best_domain [延迟: ${best_avg}ms, 抖动: $best_jitter_pct]): " server_name
server_name=${server_name:-$best_domain}

# 6. 生成密钥和 JSON
key_pair=$(/root/sing-box generate reality-keypair)
private_key=$(echo "$key_pair" | awk '/PrivateKey/ {print $2}' | tr -d '"')
public_key=$(echo "$key_pair" | awk '/PublicKey/ {print $2}' | tr -d '"')
echo "$public_key" | base64 > /root/public.key.b64
uuid=$(/root/sing-box generate uuid)
short_id=$(/root/sing-box generate rand --hex 8)

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

# 7. 启动服务
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

# 8. 输出结果
server_link="vless://$uuid@$server_ip:$listen_port?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$server_name&fp=chrome&pbk=$public_key&sid=$short_id&type=tcp&headerType=none#Singbox-REALITY"
echo -e "\n\033[32m配置成功！\033[0m"
echo "已选择最优 SNI: $server_name"
echo "服务器 IP: $server_ip"
echo -e "\n节点链接:\n\033[33m$server_link\033[0m\n"
