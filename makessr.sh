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

# 安装或更新 sing-box 最新 release
function install_singbox() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "请用 root 权限运行此脚本"
        exit 1
    fi

    enable_bbr

    apt-get update -y
    apt-get install -y curl jq tar openssl

    # 判断架构
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) SB_ARCH="amd64" ;;
        aarch64) SB_ARCH="arm64" ;;
        armv7l) SB_ARCH="armv7" ;;
        *) echo "Unsupported arch: $ARCH"; exit 1 ;;
    esac

    # 获取最新 release
    LATEST_TAG=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r '.tag_name')
    VERSION=${LATEST_TAG#v}
    URL="https://github.com/SagerNet/sing-box/releases/download/${LATEST_TAG}/sing-box-${VERSION}-linux-${SB_ARCH}.tar.gz"

    echo "下载 sing-box ${LATEST_TAG} ..."
    curl -L "$URL" -o /tmp/singbox.tar.gz
    mkdir -p /tmp/singbox
    tar -xzf /tmp/singbox.tar.gz -C /tmp/singbox

    BIN_SRC=$(find /tmp/singbox -type f -name 'sing-box' | head -n1)
    if [ -z "$BIN_SRC" ]; then
        echo "找不到 sing-box 可执行文件"
        exit 1
    fi

    mv "$BIN_SRC" "$BIN_FILE"
    chmod +x "$BIN_FILE"

    # 生成 VLESS+Reality 配置
    UUID=$(cat /proc/sys/kernel/random/uuid)
    KEYPAIR=$($BIN_FILE generate reality-keypair)
    PRIVATE_KEY=$(echo "$KEYPAIR" | grep "PrivateKey" | awk '{print $2}')
    PUBLIC_KEY=$(echo "$KEYPAIR" | grep "PublicKey" | awk '{print $2}')
    VLESS_PORT=$((RANDOM % 10000 + 10000))
    SNI="rum.hlx.page"
    SHORT_ID=$(openssl rand -hex 4)

    mkdir -p "$CONFIG_DIR"

    cat > "$CONFIG_FILE" <<EOF
{
  "log": { "level": "info" },
  "inbounds": [
    {
      "type": "vless",
      "listen": "::",
      "listen_port": ${VLESS_PORT},
      "users": [ { "uuid": "${UUID}", "flow": "xtls-rprx-vision" } ],
      "tls": {
        "enabled": true,
        "server_name": "${SNI}",
        "reality": {
          "enabled": true,
          "handshake": { "server": "${SNI}", "server_port": 443 },
          "private_key": "${PRIVATE_KEY}",
          "short_id": ["${SHORT_ID}"]
        }
      }
    }
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ],
  "route": { "final": "direct" }
}
EOF

    echo "验证配置..."
    if ! $BIN_FILE check -c "$CONFIG_FILE"; then
        echo "配置验证失败，请检查"
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
        echo "服务启动失败，查看日志:"
        journalctl -u "$SERVICE_NAME" --no-pager -n 20
        exit 1
    fi

    SERVER_IP=$(curl -s ipv4.icanhazip.com)
    VLESS_URL="vless://${UUID}@${SERVER_IP}:${VLESS_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=ios&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#Reality"

    echo -e "\n======================"
    echo "Sing-Box 最新版本 ${LATEST_TAG} 安装完成 ✅"
    echo "服务状态: $(systemctl is-active $SERVICE_NAME)"
    echo "VLESS Reality 链接:\n${VLESS_URL}"
    echo -e "管理命令:\n systemctl start|stop|restart $SERVICE_NAME\n journalctl -u $SERVICE_NAME -f"
    echo "======================"

    rm -rf /tmp/singbox*
}

# 卸载
function uninstall_singbox() {
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    rm -f "$SERVICE_FILE" "$BIN_FILE"
    rm -rf "$CONFIG_DIR"
    systemctl daemon-reload
    echo "卸载完成 ✅"
}

# 参数处理
case "$1" in
    install) install_singbox ;;
    uninstall) uninstall_singbox ;;
    restart) systemctl restart "$SERVICE_NAME" ;;
    status) systemctl status "$SERVICE_NAME" --no-pager -l ;;
    config) cat "$CONFIG_FILE" ;;
    *) echo "用法: $0 {install|uninstall|restart|status|config}"; exit 1 ;;
esac
