#!/bin/bash

# 检查是否安装了 jq，如果没有，则安装
if ! command -v jq &> /dev/null; then
    echo "jq 未安装。安装..."
    if [ -n "$(command -v apt)" ]; then
        apt update > /dev/null 2>&1
        apt install -y jq > /dev/null 2>&1
    elif [ -n "$(command -v yum)" ]; then
        yum install -y epel-release
        yum install -y jq
    elif [ -n "$(command -v dnf)" ]; then
        dnf install -y jq
    else
        echo "无法安装 jq。请手动安装 jq 并重新运行脚本."
        exit 1
    fi
fi

# 检查 reality.json、sing-box 和 sing-box.service 是否已存在
if [ -f "/root/reality.json" ] && [ -f "/root/sing-box" ] && [ -f "/root/public.key.b64" ] && [ -f "/etc/systemd/system/sing-box.service" ]; then

    echo "文件已存在."
    echo ""
    echo "请选择选项:"
    echo ""
    echo "1. 重新安装"
    echo "2. 更改配置"
    echo "3. 当前配置"
    echo "4. 选择版本（稳定版/测试版）"
    echo "5. 卸载"
    echo ""
    read -p "输入选择 (1-5): " choice

    case $choice in
        1)
            echo "重新安装..."
            systemctl stop sing-box
            systemctl disable sing-box > /dev/null 2>&1
            rm /etc/systemd/system/sing-box.service
            rm /root/reality.json
            rm /root/sing-box
            ;;
        2)
            echo "更改配置..."
            current_listen_port=$(jq -r '.inbounds[0].listen_port' /root/reality.json)
            read -p "请输入端口 (当前端口: $current_listen_port): " listen_port
            listen_port=${listen_port:-$current_listen_port}

            current_server_name=$(jq -r '.inbounds[0].tls.server_name' /root/reality.json)
            read -p "请输入域名/SNI (当前域名: $current_server_name): " server_name
            server_name=${server_name:-$current_server_name}

            # 修改配置
            jq --arg listen_port "$listen_port" --arg server_name "$server_name" '.inbounds[0].listen_port = ($listen_port | tonumber) | .inbounds[0].tls.server_name = $server_name | .inbounds[0].tls.reality.handshake.server = $server_name' /root/reality.json > /root/reality_modified.json
            mv /root/reality_modified.json /root/reality.json

            systemctl restart sing-box
            echo -e "\n配置已更新并重启服务。\n"
            # 重新生成链接 (复用下方的链接逻辑)
            ;;
        3)
            # 这里的逻辑会被下方统一的链接展示逻辑覆盖或直接在此退出
            ;;
        4)
            # 版本切换逻辑 (保持不变)
            # ... [此处省略原有的版本切换代码以节省空间，建议保留你原有的逻辑] ...
            exit 0
            ;;
        5)
            echo "卸载..."
            systemctl stop sing-box
            systemctl disable sing-box > /dev/null 2>&1
            rm /etc/systemd/system/sing-box.service /root/reality.json /root/sing-box /root/public.key.b64
            echo "完成!"
            exit 0
            ;;
    esac
fi

# --- 安装逻辑开始 ---

if [ "$choice" != "2" ] && [ "$choice" != "3" ]; then
    echo ""
    echo "请选择安装版本:"
    echo "1. 稳定版"
    echo "2. 测试版"
    read -p "请输入您的选择 (1-2, 默认: 1): " version_choice
    version_choice=${version_choice:-1}

    if [ "$version_choice" -eq 2 ]; then
        latest_version_tag=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases" | jq -r '[.[] | select(.prerelease==true)][0].tag_name')
    else
        latest_version_tag=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases" | jq -r '[.[] | select(.prerelease==false)][0].tag_name')
    fi

    latest_version=${latest_version_tag#v}
    arch=$(uname -m)
    case ${arch} in
        x86_64) arch="amd64" ;;
        aarch64) arch="arm64" ;;
        armv7l) arch="armv7" ;;
    esac

    package_name="sing-box-${latest_version}-linux-${arch}"
    url="https://github.com/SagerNet/sing-box/releases/download/${latest_version_tag}/${package_name}.tar.gz"
    
    echo "正在下载版本: $latest_version..."
    curl -sLo "/root/${package_name}.tar.gz" "$url"
    tar -xzf "/root/${package_name}.tar.gz" -C /root
    mv "/root/${package_name}/sing-box" /root/
    rm -r "/root/${package_name}.tar.gz" "/root/${package_name}"
    chown root:root /root/sing-box
    chmod +x /root/sing-box

    # 生成密钥
    key_pair=$(/root/sing-box generate reality-keypair)
    private_key=$(echo "$key_pair" | awk '/PrivateKey/ {print $2}' | tr -d '"')
    public_key=$(echo "$key_pair" | awk '/PublicKey/ {print $2}' | tr -d '"')
    echo "$public_key" | base64 > /root/public.key.b64
    uuid=$(/root/sing-box generate uuid)
    short_id=$(/root/sing-box generate rand --hex 8)

    # 交互输入
    read -p "输入端口 (默认: 443): " listen_port
    listen_port=${listen_port:-443}
    read -p "输入优选域名/SNI (默认: addons.mozilla.org): " server_name
    server_name=${server_name:-addons.mozilla.org}

    # --- 新增：IP 获取与修改逻辑 ---
    auto_ip=$(curl -s https://api.ipify.org || curl -s https://ifconfig.me)
    echo -e "\n系统自动获取的公网 IP 为: \033[32m$auto_ip\033[0m"
    read -p "是否使用此 IP？直接回车确认，如需修改请输入新 IP: " custom_ip
    server_ip=${custom_ip:-$auto_ip}
    echo -e "将使用 IP: $server_ip\n"
    # ----------------------------

    # 创建 reality.json
    jq -n --arg listen_port "$listen_port" --arg server_name "$server_name" --arg private_key "$private_key" --arg short_id "$short_id" --arg uuid "$uuid" --arg server_ip "$server_ip" '{
      "log": {"level": "info","timestamp": true},
      "inbounds": [{
          "type": "vless",
          "tag": "vless-in",
          "listen": "::",
          "listen_port": ($listen_port | tonumber),
          "sniff": true,
          "sniff_override_destination": true,
          "domain_strategy": "ipv4_only",
          "users": [{"uuid": $uuid,"flow": "xtls-rprx-vision"}],
          "tls": {
            "enabled": true,
            "server_name": $server_name,
            "reality": {
              "enabled": true,
              "handshake": {"server": $server_name,"server_port": 443},
              "private_key": $private_key,
              "short_id": [$short_id]
            }
          }
      }],
      "outbounds": [{"type": "direct","tag": "direct"},{"type": "block","tag": "block"}]
    }' > /root/reality.json

    # 创建服务文件
    cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
After=network.target nss-lookup.target

[Service]
User=root
WorkingDirectory=/root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=/root/sing-box run -c /root/reality.json
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable sing-box > /dev/null 2>&1
    systemctl restart sing-box
fi

# --- 统一输出链接部分 ---
# 如果是选项 2 或 3，需要从文件中重新读取变量
if [ "$choice" == "2" ] || [ "$choice" == "3" ]; then
    uuid=$(jq -r '.inbounds[0].users[0].uuid' /root/reality.json)
    server_ip=$(curl -s https://api.ipify.org) # 这里的展示可以保留自动获取，或引导用户修改
    listen_port=$(jq -r '.inbounds[0].listen_port' /root/reality.json)
    server_name=$(jq -r '.inbounds[0].tls.server_name' /root/reality.json)
    public_key=$(base64 --decode /root/public.key.b64)
    short_id=$(jq -r '.inbounds[0].tls.reality.short_id[0]' /root/reality.json)
fi

server_link="vless://$uuid@$server_ip:$listen_port?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$server_name&fp=chrome&pbk=$public_key&sid=$short_id&type=tcp&headerType=none#Singbox-TCP"

echo -e "\n--- 配置完成 ---"
echo "Server IP: $server_ip"
echo "Listen Port: $listen_port"
echo "Server Name: $server_name"
echo "UUID: $uuid"
echo -e "\n订阅链接 (v2rayN / v2rayNG):"
echo -e "\033[33m$server_link\033[0m\n"
