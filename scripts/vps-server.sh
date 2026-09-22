#!/bin/bash
# ============================================================================
#  openclash-mosdns-kit — VPS 端：自建加密 DNS（DoT/DoH）服务端
#
#  在你的境外 VPS（Ubuntu/Debian）上跑这一个脚本，得到：
#    - mosdns 加密 DNS 服务：DoT :853（主力）+ DoH :443
#    - 自签证书（10 年），systemd 常驻，开机自启
#    - nftables 防火墙：默认 drop，只放行你家出口 IP 的 DNS + SSH
#
#  ⚠ 设计原则：这台机器【只做缓存 + 转发，不做国内判断】。
#    防污染校验必须放在路由器侧；放 VPS 侧会把大站的正确回程 IP 误判成
#    污染丢掉，国内流量反而被送进代理（本 kit 作者踩过，血泪教训）。
#
#  用法（SSH 登录 VPS 后）：
#    HOME_IP=你家宽带的公网出口IP bash vps-server.sh
#
#  HOME_IP 怎么查：家里电脑访问 https://ip.sb 看到的地址。
#  家宽 PPPPoE 重拨后出口 IP 会变——变了就改 /etc/nftables.conf 里的
#  home_allow 再 `systemctl restart nftables`，DNS 服务本身不用动。
#
#  卸载：bash vps-server.sh uninstall
# ============================================================================
set -euo pipefail

MOSDNS_VERSION="5.3.4"
DOT_PORT=853
DOH_PORT=443
SSH_PORT="${SSH_PORT:-22}"

log() { echo "[vps-server] $*"; }
die() { echo "[vps-server][ERROR] $*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || die "需要 root"

# ---- 卸载 ----
if [ "${1:-}" = "uninstall" ]; then
    log "卸载 mosdns 服务..."
    systemctl stop mosdns 2>/dev/null || true
    systemctl disable mosdns 2>/dev/null || true
    rm -f /etc/systemd/system/mosdns.service /usr/local/bin/mosdns
    rm -rf /etc/mosdns
    log "注意：nftables 防火墙配置保留（如需还原自行处理）。"
    exit 0
fi

# ---- 前置 ----
HOME_IP="${HOME_IP:-${1:-}}"
[ -n "$HOME_IP" ] || die "必须指定你家出口 IP：HOME_IP=1.2.3.4 bash vps-server.sh（家里电脑访问 https://ip.sb 查询）"
echo "$HOME_IP" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || die "HOME_IP 格式不对：$HOME_IP"

. /etc/os-release 2>/dev/null || die "不是 Ubuntu/Debian？请手动安装"
case "${ID:-}" in ubuntu|debian) ;; *) die "本脚本仅支持 Ubuntu/Debian（当前: ${ID:-unknown}）" ;; esac

# ---- 1. 装依赖 ----
log "安装依赖..."
apt-get update -qq
apt-get install -y -qq curl ca-certificates openssl nftables >/dev/null

# ---- 2. 下载 mosdns ----
ARCH="$(uname -m)"
case "$ARCH" in
    x86_64)          MOS_PKG="mosdns-linux-amd64.zip" ;;
    aarch64|arm64)   MOS_PKG="mosdns-linux-arm64.zip" ;;
    armv7l|armhf)    MOS_PKG="mosdns-linux-armv7.zip" ;;
    *) die "不支持的架构: $ARCH" ;;
esac
if [ -x /usr/local/bin/mosdns ] && /usr/local/bin/mosdns version 2>/dev/null | grep -q "v$MOSDNS_VERSION"; then
    log "mosdns v$MOSDNS_VERSION 已存在，跳过下载"
else
    log "下载 mosdns v$MOSDNS_VERSION ($MOS_PKG)..."
    apt-get install -y -qq unzip >/dev/null
    curl -fsSL --max-time 120 "https://github.com/IrineSistiana/mosdns/releases/download/v${MOSDNS_VERSION}/${MOS_PKG}" -o /tmp/mosdns.zip \
        || die "下载失败，检查 VPS 能否访问 GitHub"
    cd /tmp && unzip -o mosdns.zip mosdns >/dev/null
    mv -f /tmp/mosdns /usr/local/bin/mosdns && chmod +x /usr/local/bin/mosdns
fi

# ---- 3. 自签证书（10 年，SAN=本机公网IP） ----
mkdir -p /etc/mosdns/certs
if [ ! -f /etc/mosdns/certs/dot.crt ] || ! openssl x509 -in /etc/mosdns/certs/dot.crt -checkend 31536000 >/dev/null 2>&1; then
    log "生成自签证书（10 年，SAN=$HOME_IP）..."
    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout /etc/mosdns/certs/dot.key \
        -out /etc/mosdns/certs/dot.crt \
        -days 3650 -subj "/CN=dns.local" \
        -addext "subjectAltName=IP:${HOME_IP}" >/dev/null 2>&1 \
        || die "证书生成失败"
    chmod 600 /etc/mosdns/certs/dot.key
fi

# ---- 4. mosdns 配置：纯缓存 + 转发，不做国内判断 ----
log "写 mosdns 配置..."
cat > /etc/mosdns/config.yaml <<EOF
log:
  file: /var/log/mosdns.log
  level: warn

plugins:
  # 上游全部走 TCP/加密：部分机房 UDP 出网会被上游静默丢弃，TCP 稳
  - tag: forward
    type: forward
    args:
      concurrent: 2
      upstreams:
        - addr: tls://1.1.1.1:853
        - addr: tls://8.8.8.8:853
        - addr: https://dns.google/dns-query

  - tag: cache
    type: cache
    args:
      size: 100000
      lazy_cache_ttl: 86400

  - tag: main
    type: sequence
    args:
      - exec: \$cache
      - exec: \$forward
      - exec: accept

  - type: tls_server
    args:
      entry: main
      listen: 0.0.0.0:${DOT_PORT}
      cert_file: /etc/mosdns/certs/dot.crt
      key_file: /etc/mosdns/certs/dot.key

  - type: https_server
    args:
      entry: main
      listen: 0.0.0.0:${DOH_PORT}
      cert_file: /etc/mosdns/certs/dot.crt
      key_file: /etc/mosdns/certs/dot.key
EOF

# ---- 5. systemd 服务 ----
log "注册 systemd 服务..."
cat > /etc/systemd/system/mosdns.service <<'EOF'
[Unit]
Description=mosdns encrypted DNS server
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/mosdns start -c /etc/mosdns/config.yaml
Restart=always
RestartSec=3
LimitNOFILE=65535
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable mosdns >/dev/null 2>&1
systemctl restart mosdns
sleep 2
systemctl is-active --quiet mosdns || { journalctl -u mosdns -n 10 --no-pager; die "mosdns 启动失败"; }
log "✓ mosdns 运行中"

# ---- 6. nftables 防火墙：默认 drop，白名单你家 IP ----
log "配置 nftables（默认 drop，只放行 $HOME_IP 的 DNS + SSH:$SSH_PORT）..."
cat > /etc/nftables.conf <<NFTEOF
#!/sbin/nft -f
flush table inet fw 2>/dev/null
table inet fw {
    chain input {
        type filter hook input priority 0; policy drop;

        iif lo accept
        ct state established,related accept
        ct state invalid drop

        icmp type echo-request limit rate 5/minute accept

        # 你家出口 IP → DNS（限速防爆破）
        ip saddr ${HOME_IP} tcp dport { ${DOT_PORT}, 443, 8443 } limit rate 5000/minute accept
        ip saddr ${HOME_IP} udp dport 53 limit rate 5000/minute accept

        # SSH 限速
        tcp dport ${SSH_PORT} ct state new limit rate 30/minute accept

        log prefix "nft-drop: " limit rate 10/minute drop
    }
}
NFTEOF
nft -c -f /etc/nftables.conf || die "nftables 配置语法错误，未加载（原防火墙未动）"
systemctl enable nftables >/dev/null 2>&1
systemctl restart nftables
log "✓ nftables 已加载"

# ---- 7. 自检 ----
log "自检 DoT 握手..."
if echo | timeout 10 openssl s_client -connect "127.0.0.1:${DOT_PORT}" >/dev/null 2>&1; then
    log "✓ DoT :${DOT_PORT} 握手正常"
else
    die "DoT 握手失败，查 /var/log/mosdns.log"
fi

echo ""
log "============================================"
log "✅ VPS 服务端部署完成"
log "  DoT:  tls://<本机IP>:${DOT_PORT}"
log "  DoH:  https://<本机IP>/dns-query（自签证书）"
log "  白名单: ${HOME_IP}（家宽出口 IP 变了记得改 /etc/nftables.conf）"
log ""
log "下一步：回路由器跑"
log "  VPS_IP=<本机IP> sh install-vps.sh"
log "============================================"
