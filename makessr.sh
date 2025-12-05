#!/bin/bash
set -e

SERVICE_NAME="sing-box"
CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="${CONFIG_DIR}/config.json"
BIN_FILE="/usr/local/bin/sing-box"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

# 启用并持久化 BBR
function enable_bbr() {
    echo "启用 BBR 拥塞控制..."
    modprobe tcp_bbr 2>/dev/null || true
    echo "tcp_bbr" > /etc/modules-load.d/bbr.conf
    cat > /etc/sysctl.d/99-bbr.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || true
    sysctl -p /etc/sysctl.d/99-bbr.conf >/dev/null 2>&1 || sysctl --system >/dev/null 2>&1 || true
    CUR_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
    AVAIL_CC=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo "")
    if [ "$CUR_CC" = "bbr" ] || echo "$AVAIL_CC" | grep -qw bbr; then
        echo "BBR 已启用（当前拥塞控制: ${CUR_CC:-unknown}）"
    else
        echo "警告：未检测到 BBR，可用拥塞控制: ${AVAIL_CC}"
    fi
}

# 安装 sing-box 并生成配置
function install_singbox() {
    if [ "$(id -u)" -ne 0 ]; then
      echo "请用 root 权限运行此脚本"
      exit 1
    fi

    enable_bbr

    apt-get update -y
    apt-get install -y curl unzip jq openssl tar

    # 获取最新版本
    LATEST_VERSION=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r '.tag_name')
    VERSION=${LATEST_VERSION#v}
    ARCH=$(uname -m)

    case "$ARCH" in
      x86_64)   SB_ARCH="amd64" ;;
      aarch64)  SB_ARCH="arm64" ;;
      armv7l)   SB_ARCH="armv7" ;;
      *) echo "不支持的架构: $ARCH"; exit 1 ;;
    esac

    URL="https://github.com/SagerNet/sing-box/releases/download/${LATEST_VERSION}/sing-box-${VERSION}-linux-${SB_ARCH}.tar.gz"
    echo "下载 sing-box: $URL"
    curl -L -o /tmp/singbox.tar.gz "$URL"
    mkdir -p /tmp/singbox
    tar -xzf /tmp/singbox.tar.gz -C /tmp/singbox

    if [ -f "/tmp/singbox/sing-box" ]; then
      SRC="/tmp/singbox/sing-box"
    elif [ -f "/tmp/singbox/sing-box-${VERSION}-linux-${SB_ARCH}/sing-box" ]; then
      SRC="/tmp/singbox/sing-box-${VERSION}-linux-${SB_ARCH}/sing-box"
    else
      SRC="$(find /tmp/singbox -type f -name 'sing-box' | head -n1)"
    fi

    if [ -z "$SRC" ]; then
      echo "解压后未找到 sing-box 可执行文件"
      exit 1
    fi

    mv "$SRC" "$BIN_FILE"
    chmod +x "$BIN_FILE"

    # 生成 VLESS+Reality 密钥、端口
    UUID=$(cat /proc/sys/kernel/random/uuid)
    KEYPAIR=$($BIN_FILE generate reality-keypair)
    PRIVATE_KEY=$(echo "$KEYPAIR" | grep "PrivateKey" | awk '{print $2}')
    PUBLIC_KEY=$(echo "$KEYPAIR" | grep "PublicKey" | awk '{print $2}')
    VLESS_PORT=$((RANDOM % 10000 + 10000))
    SNI="gateway.icloud.com"
    SHORT_ID=$(openssl rand -hex 4)

    # Hysteria2 配置
    HYSTERIA_PORT=$((RANDOM % 10000 + 20000))
    HYSTERIA_PASSWORD=$(openssl rand -hex 8)

    # TUIC 配置
    TUIC_PORT=$((RANDOM % 10000 + 30000))
    TUIC_PASSWORD=$(openssl rand -hex 8)

    mkdir -p "$CONFIG_DIR"

    # 生成完整配置文件
    cat > "$CONFIG_FILE" <<EOF
{
  "log": {
    "level": "info"
  },
  "inbounds": [
    {
      "type": "vless",
      "listen": "::",
      "listen_port": ${VLESS_PORT},
      "users": [
        {
          "uuid": "${UUID}",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${SNI}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${SNI}",
            "server_port": 443
          },
          "private_key": "${PRIVATE_KEY}",
          "short_id": ["${SHORT_ID}"]
        }
      }
    },
    {
      "type": "hysteria",
      "listen": "::",
      "listen_port": ${HYSTERIA_PORT},
      "obfs": "udp",
      "auth_type": "password",
      "auth_password": "${HYSTERIA_PASSWORD}",
      "tls": {
        "enabled": true,
        "server_name": "${SNI}"
      }
    },
    {
      "type": "tuic",
      "listen": "::",
      "listen_port": ${TUIC_PORT},
      "auth_type": "password",
      "auth_password": "${TUIC_PASSWORD}",
      "tls": {
        "enabled": true,
        "server_name": "${SNI}"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "final": "direct"
  }
}
EOF

    # 验证配置
    echo "验证配置文件..."
    if ! $BIN_FILE check -c "$CONFIG_FILE"; then
        echo "配置文件验证失败！"
        exit 1
    fi

    # systemd 服务
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Sing-Box Service
After=network.target

[Service]
ExecStart=$BIN_FILE run -c $CONFIG_FILE
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
    systemctl restart "$SERVICE_NAME"
    sleep 3

    if ! systemctl is-active --quiet "$SERVICE_NAME"; then
        echo "服务启动失败！查看日志："
        journalctl -u "$SERVICE_NAME" --no-pager -n 20
        exit 1
    fi

    SERVER_IP=$(curl -s ipv4.icanhazip.com)

    # 输出 VLESS Reality 链接
    VLESS_URL="vless://${UUID}@${SERVER_IP}:${VLESS_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=ios&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#Reality"

    echo -e "\n======================"
    echo "Sing-Box 安装完成 ✅"
    echo "服务状态: $(systemctl is-active $SERVICE_NAME)"
    echo -e "\nVLESS Reality 链接:"
    echo "${VLESS_URL}"
    echo -e "\nHysteria2 信息:"
    echo "IP: $SERVER_IP"
    echo "Port: $HYSTERIA_PORT"
    echo "Password: $HYSTERIA_PASSWORD"
    echo "Protocol: udp"
    echo "TLS: true"
    echo "SNI: $SNI"
    echo -e "\nTUIC 信息:"
    echo "IP: $SERVER_IP"
    echo "Port: $TUIC_PORT"
    echo "Password: $TUIC_PASSWORD"
    echo "TLS: true"
    echo "SNI: $SNI"
    echo -e "\n管理命令："
    echo "启动服务: systemctl start $SERVICE_NAME"
    echo "停止服务: systemctl stop $SERVICE_NAME"
    echo "重启服务: systemctl restart $SERVICE_NAME"
    echo "查看状态: systemctl status $SERVICE_NAME"
    echo "查看日志: journalctl -u $SERVICE_NAME -f"
    echo "======================"

    rm -rf /tmp/singbox*
}

# 卸载
function uninstall_singbox() {
    echo "停止服务..."
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload
    rm -rf "$CONFIG_DIR"
    rm -f "$BIN_FILE"
    echo "卸载完成 ✅"
}

# 重启
function restart_singbox() {
    echo "重启服务..."
    systemctl restart "$SERVICE_NAME"
    sleep 2
    systemctl status "$SERVICE_NAME" --no-pager -l
}

# 查看状态
function status_singbox() {
    echo "=== 服务状态 ==="
    systemctl status "$SERVICE_NAME" --no-pager -l
    echo -e "\n=== 监听端口 ==="
    ss -tlnp | grep sing-box || echo "未找到监听端口"
    echo -e "\n=== 最近日志 ==="
    journalctl -u "$SERVICE_NAME" --no-pager -n 10
}

# 查看配置
function show_config() {
    if [ -f "$CONFIG_FILE" ]; then
        echo "=== 当前配置 ==="
        cat "$CONFIG_FILE"
    else
        echo "配置文件不存在: $CONFIG_FILE"
    fi
}

# 参数处理
case "$1" in
    install)
        install_singbox
        ;;
    uninstall)
        uninstall_singbox
        ;;
    restart)
        restart_singbox
        ;;
    status)
        status_singbox
        ;;
    config)
        show_config
        ;;
    *)
        echo "用法: $0 {install|uninstall|restart|status|config}"
        exit 1
        ;;
esac