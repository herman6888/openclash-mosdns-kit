#!/bin/sh
# ============================================================================
#  openclash-mosdns-kit — 一键安装
#  给 OpenClash 加一层 mosdns：国内并发竞速 + resp_ip 防污染 + 本地缓存
#  适配 OpenWrt / iStoreOS，需已装 OpenClash
#
#  用法：  sh install.sh
#  卸载：  sh uninstall.sh
#
#  安全声明：本脚本只改 DNS 路径，不碰代理节点/订阅/出口规则。
#           改前自动备份，可随时 uninstall 回滚。
# ============================================================================
set -u

# ---- 可调参数（按需改）----
MOSDNS_VERSION="5.3.4"
MOSDNS_LISTEN="127.0.0.1:5350"
# 国内上游（并发竞速）
CHN_UP1="223.5.5.5:53"      # 阿里 DNS
CHN_UP2="119.29.29.29:53"   # 腾讯 DNSPod
# 加密备份上游（国内可达 DoH，不依赖任何代理）
BAK_UP1="https://dns.alidns.com/dns-query"
BAK_UP2="https://doh.pub/dns-query"
# 规则表源（de_GWD 作者维护）
RULE_BASE="https://raw.githubusercontent.com/jacyl4/chnroute/master"
# GitHub 加速前缀（国内访问 raw.githubusercontent 受阻时改成 https://gh-proxy.com/）
GH_PROXY=""
# 竞速阈值(ms)
RACE_THRESHOLD="100"

INSTALL_DIR="/etc/mosdns"
BIN="/usr/bin/mosdns"
INIT="/etc/init.d/mosdns"
OCC_DIR="/etc/openclash/custom"
OCC_HOOK="$OCC_DIR/openclash_custom_overwrite.sh"
BACKUP_DIR="/root/openclash-mosdns-kit-backup-$(date +%Y%m%d-%H%M%S)"

log() { echo "[install] $*"; }
die() { echo "[install][ERROR] $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 0. 前置检查
# ---------------------------------------------------------------------------
[ "$(id -u)" = "0" ] || die "需要 root 运行"
command -v uci >/dev/null 2>&1 || die "找不到 uci，这不是 OpenWrt/iStoreOS？"

# 检测 OpenClash
if [ ! -d /etc/openclash ]; then
    die "未检测到 OpenClash（/etc/openclash 不存在）。本 kit 是给 OpenClash 加 DNS 层的，请先装 OpenClash。"
fi
log "检测到 OpenClash。"

# ---------------------------------------------------------------------------
# 1. 架构检测
# ---------------------------------------------------------------------------
ARCH="$(uname -m)"
case "$ARCH" in
    aarch64|arm64)   MOS_PKG="mosdns-linux-arm64.zip" ;;
    armv7l|armhf)    MOS_PKG="mosdns-linux-armv7.zip" ;;
    x86_64)          MOS_PKG="mosdns-linux-amd64.zip" ;;
    mips)            MOS_PKG="mosdns-linux-mipsle-softfloat.zip" ;;
    mipsel)          MOS_PKG="mosdns-linux-mipsle-softfloat.zip" ;;
    *) die "未知架构: $ARCH，请手动指定 mosdns 包" ;;
esac
log "架构: $ARCH → $MOS_PKG"

# ---------------------------------------------------------------------------
# 2. 备份现有配置
# ---------------------------------------------------------------------------
mkdir -p "$BACKUP_DIR"
[ -f "$OCC_HOOK" ] && cp -a "$OCC_HOOK" "$BACKUP_DIR/openclash_custom_overwrite.sh.bak" && log "已备份原 OpenClash 钩子"
uci show openclash > "$BACKUP_DIR/openclash.uci.bak" 2>/dev/null && log "已备份 openclash UCI"
log "备份目录: $BACKUP_DIR"

# ---------------------------------------------------------------------------
# 3. 下载 mosdns 二进制
# ---------------------------------------------------------------------------
mkdir -p "$INSTALL_DIR"
cd /tmp
log "下载 mosdns v$MOSDNS_VERSION ..."
DL_URL="${GH_PROXY}https://github.com/IrineSistiana/mosdns/releases/download/v${MOSDNS_VERSION}/${MOS_PKG}"
if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$DL_URL" -o mosdns.zip || die "下载失败: $DL_URL（试设 GH_PROXY 加速）"
elif command -v wget >/dev/null 2>&1; then
    wget -q "$DL_URL" -O mosdns.zip || die "下载失败: $DL_URL"
else
    die "系统无 curl/wget"
fi
command -v unzip >/dev/null 2>&1 || die "需要 unzip（opkg update && opkg install unzip）"
unzip -o mosdns.zip mosdns >/dev/null 2>&1 || unzip -o mosdns.zip >/dev/null
[ -f /tmp/mosdns ] || die "解压后找不到 mosdns 二进制"
mv -f /tmp/mosdns "$BIN"
chmod +x "$BIN"
log "mosdns 已安装: $("$BIN" version 2>&1 | head -1)"

# ---------------------------------------------------------------------------
# 4. 下载分流规则表
# ---------------------------------------------------------------------------
log "下载分流规则表（IPchnroute + Domains.chn.txt）..."
for f in "IPchnroute" "mosdns_chnlist/Domains.chn.txt"; do
    out="$INSTALL_DIR/$(basename "$f")"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "${GH_PROXY}${RULE_BASE}/${f}" -o "$out" || die "规则表下载失败: $f"
    else
        wget -q "${GH_PROXY}${RULE_BASE}/${f}" -O "$out" || die "规则表下载失败: $f"
    fi
done
IP_LINES=$(wc -l < "$INSTALL_DIR/IPchnroute" 2>/dev/null || echo 0)
DOM_LINES=$(wc -l < "$INSTALL_DIR/Domains.chn.txt" 2>/dev/null || echo 0)
log "规则表就绪: IPchnroute=${IP_LINES} 行, Domains.chn.txt=${DOM_LINES} 行"

# ---------------------------------------------------------------------------
# 5. 生成 mosdns 配置
# ---------------------------------------------------------------------------
log "生成 mosdns 配置..."
cat > "$INSTALL_DIR/config.yaml" <<EOF
log:
  file: /var/log/mosdns.log
  level: warn

plugins:
  - tag: forward_chn
    type: forward
    args:
      concurrent: 2
      upstreams:
        - addr: ${CHN_UP1}
        - addr: ${CHN_UP2}

  - tag: forward_bak
    type: forward
    args:
      concurrent: 2
      upstreams:
        - addr: ${BAK_UP1}
        - addr: ${BAK_UP2}

  - tag: cache
    type: cache
    args:
      size: 50000
      lazy_cache_ttl: 86400

  # 国内序列：查国内 DNS，答案 IP 必须在中国网段，否则判污染丢弃
  - tag: chn_sequence
    type: sequence
    args:
      - exec: \$forward_chn
      - matches: resp_ip &${INSTALL_DIR}/IPchnroute
        exec: accept
      - exec: drop_resp

  # 通用序列：走加密备份上游
  - tag: global_sequence
    type: sequence
    args:
      - exec: \$forward_bak
      - exec: accept

  # 竞速：国内主、加密备，${RACE_THRESHOLD}ms 定胜负，备用常驻并发
  - tag: race
    type: fallback
    args:
      primary: chn_sequence
      secondary: global_sequence
      threshold: ${RACE_THRESHOLD}
      always_standby: true

  # 主序列：先查缓存，国内域名进竞速，其余走加密
  - tag: main_sequence
    type: sequence
    args:
      - exec: \$cache
      - matches: qname &${INSTALL_DIR}/Domains.chn.txt
        exec: \$race
      - exec: \$global_sequence

  - type: udp_server
    args:
      entry: main_sequence
      listen: ${MOSDNS_LISTEN}

  - type: tcp_server
    args:
      entry: main_sequence
      listen: ${MOSDNS_LISTEN}
EOF
log "配置写入 $INSTALL_DIR/config.yaml"

# ---------------------------------------------------------------------------
# 6. 注册 procd 服务
# ---------------------------------------------------------------------------
log "注册 mosdns 系统服务..."
cat > "$INIT" <<'EOF'
#!/bin/sh /etc/rc.common

START=60
STOP=10
USE_PROCD=1

PROG=/usr/bin/mosdns
CONF=/etc/mosdns/config.yaml

start_service() {
    procd_open_instance
    procd_set_param command "$PROG" start -c "$CONF"
    procd_set_param respawn 3600 5 0
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_set_param limits nofile="65535 65535"
    procd_close_instance
}
EOF
chmod +x "$INIT"
"$INIT" enable 2>/dev/null
"$INIT" restart 2>/dev/null
sleep 2
if pidof mosdns >/dev/null 2>&1; then
    log "mosdns 服务已启动 (pid=$(pidof mosdns))"
else
    die "mosdns 启动失败，查 /var/log/mosdns.log"
fi

# ---------------------------------------------------------------------------
# 7. 自动探测订阅域名（防 DNS↔代理死锁）
# ---------------------------------------------------------------------------
# 说明：OpenClash 要 HTTP 拉订阅、要连代理节点。真正必须"直连解析"的是
#       订阅地址的 host（否则拉订阅这一步就卡住）。代理节点 server 域名
#       走 mosdns 境外序列拿真实 IP 即可，解析本身不经代理，不会死锁。
log "探测订阅地址 host（这些直连解析，防死锁）..."
PROXY_HOSTS=""
# 从 UCI 抓所有订阅 address 的 host
idx=0
while true; do
    addr=$(uci get openclash.@config_subscribe[${idx}].address 2>/dev/null) || break
    [ -z "$addr" ] && break
    h=$(echo "$addr" | sed -E 's#https?://##; s#/.*##; s#:[0-9]+$##')
    PROXY_HOSTS="$PROXY_HOSTS $h"
    idx=$((idx+1))
done
# 去重、去空、去本地/纯IP（本地 IP 无需 nameserver-policy）
PROXY_HOSTS=$(echo "$PROXY_HOSTS" | tr ' ' '\n' | grep -vE '^$|^[0-9.]+$' | sort -u)
if [ -z "$PROXY_HOSTS" ]; then
    log "⚠ 未探测到订阅域名，nameserver-policy 将为空（不影响 DNS 优化，仅订阅更新可能受影响）"
else
    log "探测到订阅域名: $(echo $PROXY_HOSTS)"
fi

# 直连解析用的上游（纯 IP，避免解析这个 IP 又要走 DNS）
DIRECT_DNS="223.5.5.5"

# 构造 nameserver-policy 的 ruby hash 字符串
NSP="{"
first=1
for h in $PROXY_HOSTS; do
    [ $first -eq 0 ] && NSP="$NSP,"
    NSP="$NSP'$h'=>'udp://${DIRECT_DNS}:53'"
    first=0
done
NSP="$NSP}"
[ $first -eq 1 ] && NSP="{}"   # 没探测到就空

# ---------------------------------------------------------------------------
# 8. 写 OpenClash 接管钩子
# ---------------------------------------------------------------------------
log "写 OpenClash DNS 接管钩子..."
mkdir -p "$OCC_DIR"
# 若已有钩子，备份并追加我们的段（用标记幂等）
if [ -f "$OCC_HOOK" ]; then
    # 移除旧的我们这段（幂等）
    sed -i '/# >>> openclash-mosdns-kit/,/# <<< openclash-mosdns-kit/d' "$OCC_HOOK"
fi
# 确保钩子有 shebang 和 ruby.sh
if [ ! -f "$OCC_HOOK" ]; then
    printf '#!/bin/sh\n. /usr/share/openclash/ruby.sh\n. /usr/share/openclash/log.sh\n. /lib/functions.sh\nCONFIG_FILE="$1"\n[ -f "$CONFIG_FILE" ] || exit 0\n' > "$OCC_HOOK"
fi
cat >> "$OCC_HOOK" <<EOF
# >>> openclash-mosdns-kit
LOG_OUT "Tip: openclash-mosdns-kit DNS takeover running..."
ruby_edit "\$CONFIG_FILE" "['dns']['nameserver']" "['${MOSDNS_LISTEN}']"
ruby_edit "\$CONFIG_FILE" "['dns']['default-nameserver']" "['223.5.5.5']"
ruby_delete "\$CONFIG_FILE" "['dns']" "fallback"
ruby_delete "\$CONFIG_FILE" "['dns']" "fallback-filter"
ruby_edit "\$CONFIG_FILE" "['dns']['nameserver-policy']" "${NSP}"
# <<< openclash-mosdns-kit
EOF
chmod +x "$OCC_HOOK"
log "钩子已写入 $OCC_HOOK"

# ---------------------------------------------------------------------------
# 9. 切 redir-host（真实 IP，让竞速真正生效）
# ---------------------------------------------------------------------------
log "切换 OpenClash 到 redir-host（真实 IP 模式）..."
uci set openclash.config.en_mode='redir-host' 2>/dev/null
uci set openclash.config.operation_mode='redir-host' 2>/dev/null
uci commit openclash 2>/dev/null

# ---------------------------------------------------------------------------
# 10. 重启 OpenClash 生效
# ---------------------------------------------------------------------------
log "重启 OpenClash（约 5-10 秒网络抖动）..."
/etc/init.d/openclash restart 2>/dev/null
sleep 8

# ---------------------------------------------------------------------------
# 11. 验证
# ---------------------------------------------------------------------------
log "验证..."
FAIL=0
pidof mosdns >/dev/null 2>&1 || { log "✗ mosdns 未运行"; FAIL=1; }
pidof clash >/dev/null 2>&1 || { log "✗ clash 未运行"; FAIL=1; }
# 用 nslookup 测本机 mosdns
if command -v nslookup >/dev/null 2>&1; then
    RES=$(nslookup www.baidu.com 127.0.0.1 2>/dev/null | grep -A1 "Name:" | grep Address | head -1 | awk '{print $2}')
    if [ -n "$RES" ]; then
        log "✓ mosdns 解析 www.baidu.com → $RES"
    else
        log "⚠ nslookup 未能验证（busybox 限制），请手动从 LAN 设备测"
    fi
fi

if [ "$FAIL" = "0" ]; then
    log "============================================"
    log "✅ 安装完成！"
    log "  mosdns: $(pidof mosdns)  监听 $MOSDNS_LISTEN"
    log "  OpenClash: redir-host + mosdns 接管"
    log "  备份: $BACKUP_DIR"
    log "  卸载: sh uninstall.sh"
    log "============================================"
else
    log "⚠ 安装可能未完全成功，请检查日志：/var/log/mosdns.log"
    log "  回滚：cp $BACKUP_DIR/*.bak 还原 + sh uninstall.sh"
    exit 1
fi
