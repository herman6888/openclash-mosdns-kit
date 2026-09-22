#!/bin/sh
# ============================================================================
#  openclash-mosdns-kit — 一键安装（无 VPS 版）
#  给路由器加一层 mosdns：国内并发竞速 + 按回程 IP 防污染 + 本地缓存
#  适配 OpenWrt / iStoreOS，自动检测 OpenClash，有无均可用
#
#  用法：  sh install.sh
#  卸载：  sh uninstall.sh
#
#  可选环境变量：
#    HIJACK_LAN_DNS=1            无 OpenClash 时追加 nftables 劫持，强制局域网
#                                里写死第三方 DNS 的设备也走 mosdns
#    LAN_IF=br-lan               劫持生效的局域网接口（默认 br-lan）
#    GH_PROXY=https://gh-proxy.com/  GitHub 访问受阻时设加速前缀
#
#  有自建 VPS 的请用 install-vps.sh（要求 OpenClash，见 README）。
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
CHN_UP3="114.114.114.114:53"  # 114 DNS
CHN_UP4="117.50.10.10:53"     # CNNIC DNS
CHN_UP5="223.6.6.6:53"        # 阿里备用
# 境外/兜底上游 —— 按接管模式区分，见下方赋值
# 架构说明（v4，不依赖域名表完整性）：
#   所有查询先进国内竞速池；答案 IP 落在中国网段 → 采纳（国内域名，含域名表
#   缺失的子域）；不在 CN 网段（真境外域名或被污染）→ 走兜底序列。
#   OpenClash 模式：国外域名由 OpenClash fake-ip 秒回假地址、代理节点真解析，
#     mosdns 兜底用国内 DNS 快速应答即可，彻底不碰境外 DoH —— 实测境内裸连
#     境外 DoH 间歇 TLS 超时，押它会偶发解析失败。
#   dnsmasq 模式（无代理）：国外域名没有代理可走，境外 DoH 是唯一出路，必须保留。
# ⚠ 实测教训：阿里/腾讯 DoH 是【境内】节点，对境外被墙域名返回污染答案，不能当境外上游。
BAK_UP1=""   # 在模式检测后按 KIT_MODE 赋值
BAK_UP2=""
BAK_BOOT1="223.5.5.5"
BAK_BOOT2="223.5.5.5"
# 规则表源（CN 网段表，每日自动更新）
RULE_BASE="https://raw.githubusercontent.com/herman6888/openclash-mosdns-kit/main/data"
# GitHub 加速前缀（国内访问 raw.githubusercontent 受阻时改成 https://gh-proxy.com/）
GH_PROXY="${GH_PROXY:-}"
# 竞速阈值(ms)
RACE_THRESHOLD="100"
# 是否劫持局域网 53 端口（仅无 OpenClash 模式有意义）
HIJACK_LAN_DNS="${HIJACK_LAN_DNS:-0}"
LAN_IF="${LAN_IF:-br-lan}"
# 自建 VPS DoT 地址（本脚本默认空 = 无 VPS；install-vps.sh 会注入）
VPS_IP="${VPS_IP:-}"

INSTALL_DIR="/etc/mosdns"
BIN="/usr/bin/mosdns"
INIT="/etc/init.d/mosdns"
OCC_DIR="/etc/openclash/custom"
OCC_HOOK="$OCC_DIR/openclash_custom_overwrite.sh"
OCC_FW_HOOK="$OCC_DIR/openclash_custom_firewall_rules.sh"
MODE_FILE="$INSTALL_DIR/.kit-mode"
BACKUP_DIR="/root/openclash-mosdns-kit-backup-$(date +%Y%m%d-%H%M%S)"

log() { echo "[install] $*"; }
die() { echo "[install][ERROR] $*" >&2; exit 1; }

fetch() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --max-time 60 "$1" -o "$2"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T 60 "$1" -O "$2"
    else
        die "系统无 curl/wget"
    fi
}

# 安全写入 OpenClash DNS 接管钩子。
# ⚠ OpenClash 自带模板以 `exit 0` 结尾且**不带换行符**，直接 `cat >>` 会粘成
#   `exit 0# >>> ...`，shell 走到 exit 0 就退出 → 接管代码变成永不执行的死代码。
#   所以必须先剥掉尾部空行与 exit 0，再追加，最后自己补一个 exit 0。
write_takeover_hook() {
    NSP_ARG="$1"
    mkdir -p "${OCC_DIR:-$(dirname "$OCC_HOOK")}"
    if [ -f "$OCC_HOOK" ]; then
        # 幂等：清掉上一次写入的接管段
        sed -i '/# >>> openclash-mosdns-kit/,/# <<< openclash-mosdns-kit/d' "$OCC_HOOK"
        # 去掉尾部空行（awk 全量重写，文件仅数 KB）
        awk '{ L[NR]=$0 } END { k=NR; while (k>0 && L[k] ~ /^[ \t]*$/) k--; for (i=1;i<=k;i++) print L[i] }' \
            "$OCC_HOOK" > "$OCC_HOOK.tmp" && mv "$OCC_HOOK.tmp" "$OCC_HOOK"
        # 逐层剥掉尾部的 exit 0
        while [ -s "$OCC_HOOK" ] && [ "$(tail -1 "$OCC_HOOK" | tr -d ' \t')" = "exit0" ]; do
            sed -i '$d' "$OCC_HOOK"
        done
    else
        printf '#!/bin/sh\n. /usr/share/openclash/ruby.sh\n. /usr/share/openclash/log.sh\n. /lib/functions.sh\nCONFIG_FILE="$1"\n[ -f "$CONFIG_FILE" ] || exit 0\n' > "$OCC_HOOK"
    fi
    # 保底：EOF 必须有换行，否则又会粘连
    [ -s "$OCC_HOOK" ] && [ "$(tail -c 1 "$OCC_HOOK" | wc -l)" -eq 0 ] && echo "" >> "$OCC_HOOK"

    {
        echo "# >>> openclash-mosdns-kit"
        echo 'LOG_OUT "Tip: openclash-mosdns-kit DNS takeover running..."'
        echo "ruby_edit \"\$CONFIG_FILE\" \"['dns']['nameserver']\" \"['${MOSDNS_LISTEN}']\""
        echo "ruby_edit \"\$CONFIG_FILE\" \"['dns']['default-nameserver']\" \"['223.5.5.5']\""
        echo "ruby_delete \"\$CONFIG_FILE\" \"['dns']\" \"fallback\""
        echo "ruby_delete \"\$CONFIG_FILE\" \"['dns']\" \"fallback-filter\""
        [ -n "$NSP_ARG" ] && echo "ruby_edit \"\$CONFIG_FILE\" \"['dns']['nameserver-policy']\" \"${NSP_ARG}\""
        echo "# <<< openclash-mosdns-kit"
        echo "exit 0"
    } >> "$OCC_HOOK"
    chmod +x "$OCC_HOOK"
}

# 有 VPS 时：在 OpenClash 防火墙钩子里放行 VPS，防 DoT 连接被 TUN 劫持成环。
write_vps_bypass() {
    [ -n "$VPS_IP" ] || return 0
    mkdir -p "$OCC_DIR"
    if [ -f "$OCC_FW_HOOK" ]; then
        sed -i '/# >>> openclash-mosdns-kit/,/# <<< openclash-mosdns-kit/d' "$OCC_FW_HOOK"
    else
        printf '#!/bin/sh\n. /usr/share/openclash/log.sh\n. /lib/functions.sh\n' > "$OCC_FW_HOOK"
    fi
    [ -s "$OCC_FW_HOOK" ] && [ "$(tail -c 1 "$OCC_FW_HOOK" | wc -l)" -eq 0 ] && echo "" >> "$OCC_FW_HOOK"
    {
        echo "# >>> openclash-mosdns-kit"
        echo "# 自建 DNS 服务器直连 bypass（防止 OpenClash 劫持到自家 DoT 造成环路）"
        echo "VPS_IP=\"$VPS_IP\""
        echo "nft insert rule inet fw4 openclash ip daddr \$VPS_IP counter return 2>/dev/null"
        echo "nft insert rule inet fw4 openclash_output ip daddr \$VPS_IP counter return 2>/dev/null"
        echo "LOG_OUT \"Bypass added for DNS server \$VPS_IP\""
        echo "# <<< openclash-mosdns-kit"
        echo "exit 0"
    } >> "$OCC_FW_HOOK"
    chmod +x "$OCC_FW_HOOK"
    log "VPS bypass 防火墙规则已写入 $OCC_FW_HOOK"
}

# ---------------------------------------------------------------------------
# 0. 前置检查 + 模式检测
# ---------------------------------------------------------------------------
[ "$(id -u)" = "0" ] || die "需要 root 运行"
command -v uci >/dev/null 2>&1 || die "找不到 uci，这不是 OpenWrt/iStoreOS？"

# 自动检测 OpenClash：装了且启用 → 走 OpenClash 接管；否则直接接管 dnsmasq
HAS_OC=0
OC_ENABLED=""
[ -d /etc/openclash ] && HAS_OC=1
[ -f /etc/init.d/openclash ] || HAS_OC=0
OC_ENABLED="$(uci get openclash.config.enable 2>/dev/null || true)"

if [ "$HAS_OC" = "1" ] && [ "$OC_ENABLED" = "1" ]; then
    KIT_MODE="openclash"
    log "检测到已启用的 OpenClash → 接管模式：OpenClash DNS 指向 mosdns"
    if [ -n "$VPS_IP" ]; then
        BAK_UP1="tls://${VPS_IP}:853"
        BAK_UP2="tls://${VPS_IP}:853"
    else
        # 国外走 fake-ip+代理，mosdns 兜底用国内 DNS（不押境外 DoH）
        BAK_UP1="223.5.5.5:53"
        BAK_UP2="119.29.29.29:53"
    fi
else
    if [ -n "$VPS_IP" ]; then
        die "VPS 模式必须安装并启用 OpenClash。请先装好 OpenClash 并配好订阅再跑 install-vps.sh。"
    fi
    KIT_MODE="dnsmasq"
    # 无代理：国外域名唯一出路是境外 DoH（答案干净），必须保留
    BAK_UP1="https://dns.google/dns-query"
    BAK_UP2="https://cloudflare-dns.com/dns-query"
    if [ "$HAS_OC" = "1" ]; then
        log "检测到 OpenClash 但未启用（enable=$OC_ENABLED）→ 接管模式：dnsmasq 直连 mosdns"
        log "（同时预写 OpenClash 钩子，日后启用 OpenClash 会自动接上 mosdns）"
    else
        log "未检测到 OpenClash → 接管模式：dnsmasq 直连 mosdns"
    fi
fi

# 劫持模式下 mosdns 必须监听所有网卡，否则 nft redirect 送不到
if [ "$KIT_MODE" = "dnsmasq" ] && [ "$HIJACK_LAN_DNS" = "1" ]; then
    MOSDNS_LISTEN="0.0.0.0:5350"
    log "已开启局域网 DNS 劫持，mosdns 监听改为 $MOSDNS_LISTEN"
fi

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
[ -f "$OCC_FW_HOOK" ] && cp -a "$OCC_FW_HOOK" "$BACKUP_DIR/openclash_custom_firewall_rules.sh.bak"
[ "$HAS_OC" = "1" ] && uci show openclash > "$BACKUP_DIR/openclash.uci.bak" 2>/dev/null && log "已备份 openclash UCI"
# dnsmasq / dhcp 配置备份（两种模式都备，回滚用）
cp -a /etc/config/dhcp "$BACKUP_DIR/dhcp.bak" 2>/dev/null && log "已备份 /etc/config/dhcp"
cp -a /etc/sysctl.conf "$BACKUP_DIR/sysctl.conf.bak" 2>/dev/null
log "备份目录: $BACKUP_DIR"

# ---------------------------------------------------------------------------
# 3. 下载 mosdns 二进制
# ---------------------------------------------------------------------------
mkdir -p "$INSTALL_DIR"
cd /tmp
# 幂等：已装且版本一致就跳过（省 20MB，也让重试不必重下）
# 注意：跳过下载时也必须跳过 unzip/mv，否则会拿 /tmp 里的陈旧 zip 覆盖现有二进制
CUR_VER="$([ -x "$BIN" ] && "$BIN" version 2>/dev/null | head -1 | tr -d 'v' | cut -d- -f1 || true)"
if [ "$CUR_VER" = "$MOSDNS_VERSION" ]; then
    log "已安装 mosdns v$MOSDNS_VERSION，跳过下载与解压"
else
    log "下载 mosdns v$MOSDNS_VERSION ..."
    rm -f /tmp/mosdns.zip /tmp/mosdns
    DL_PATH="https://github.com/IrineSistiana/mosdns/releases/download/v${MOSDNS_VERSION}/${MOS_PKG}"
    OK=0
    # 先试用户指定前缀，再试直连，最后试公共加速站
    for pre in "${GH_PROXY}" "" "https://gh-proxy.com/" "https://ghfast.top/"; do
        [ "$OK" = "1" ] && break
        log "  尝试源: ${pre:-（直连）}"
        fetch "${pre}${DL_PATH}" /tmp/mosdns.zip && [ -s /tmp/mosdns.zip ] && OK=1
    done
    [ "$OK" = "1" ] || die "下载失败: $DL_PATH（GitHub 暂时不可达，稍后重试或手动放 zip 到 /tmp/mosdns.zip）"
    command -v unzip >/dev/null 2>&1 || die "需要 unzip（opkg update && opkg install unzip）"
    unzip -o mosdns.zip mosdns >/dev/null 2>&1 || unzip -o mosdns.zip >/dev/null
    [ -f /tmp/mosdns ] || die "解压后找不到 mosdns 二进制"
    mv -f /tmp/mosdns "$BIN"
    chmod +x "$BIN"
    log "mosdns 已安装: $("$BIN" version 2>&1 | head -1)"
fi

# ---------------------------------------------------------------------------
# 4. 下载 CN 网段表（防污染判定用；v4 核心不依赖域名表完整性）
# ---------------------------------------------------------------------------
log "下载 CN 网段表（IPchnroute）..."
fetch "${GH_PROXY}${RULE_BASE}/IPchnroute" "$INSTALL_DIR/IPchnroute" || die "网段表下载失败"
IP_LINES=$(wc -l < "$INSTALL_DIR/IPchnroute" 2>/dev/null || echo 0)
log "网段表就绪: IPchnroute=${IP_LINES} 行"

# ---------------------------------------------------------------------------
# 5. 生成 mosdns 配置（v4：resp_ip 兜底，不靠域名表）
# ---------------------------------------------------------------------------
log "生成 mosdns 配置..."
VPS_TLS_OPT=""
[ -n "$VPS_IP" ] && VPS_TLS_OPT="
          insecure_skip_verify: true"

cat > "$INSTALL_DIR/config.yaml" <<EOF
log:
  file: /var/log/mosdns.log
  level: warn

plugins:
  - tag: forward_chn
    type: forward
    args:
      concurrent: 5
      upstreams:
        - addr: ${CHN_UP1}
        - addr: ${CHN_UP2}
        - addr: ${CHN_UP3}
        - addr: ${CHN_UP4}
        - addr: ${CHN_UP5}

  - tag: forward_bak
    type: forward
    args:
      concurrent: 2
      upstreams:
        - addr: ${BAK_UP1}${VPS_TLS_OPT}
        - addr: ${BAK_UP2}${VPS_TLS_OPT}

  - tag: cache
    type: cache
    args:
      size: 50000
      lazy_cache_ttl: 86400

  # 国内序列：查国内竞速池，答案 IP 必须在中国网段，否则判污染丢弃
  - tag: chn_sequence
    type: sequence
    args:
      - exec: \$forward_chn
      - matches: resp_ip &${INSTALL_DIR}/IPchnroute
        exec: accept
      - exec: drop_resp

  # 兜底序列：境外域名走这里（DoH 或自建 VPS DoT）
  - tag: global_sequence
    type: sequence
    args:
      - exec: \$forward_bak
      - exec: accept

  # 核心：所有查询先试国内（带 CN 网段校验），${RACE_THRESHOLD}ms 内拿到
  # CN 答案就用；国内答案不在 CN 网段（=真境外域名或被污染）→ 走兜底。
  # 不依赖域名表完整性：域名表缺子域（如 www.jd.com 只收录了 jd.com）
  # 也能正确落国内。
  - tag: race
    type: fallback
    args:
      primary: chn_sequence
      secondary: global_sequence
      threshold: ${RACE_THRESHOLD}
      always_standby: true

  - tag: main_sequence
    type: sequence
    args:
      - exec: \$cache
      - exec: \$race

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
# 6. 注册 procd 服务（含 nice=-11，DNS 进程优先调度）
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
    procd_set_param nice -11
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
# 6.5 内核 / dnsmasq 调优（P0/P1/P2，全部可回滚）
# ---------------------------------------------------------------------------
log "应用内核与 dnsmasq 调优..."

# P0-1: dnsmasq 并发上限 150 → 10000
# ⚠ UCI 选项名是 dnsforwardmax（不是 dns_forward_max），写错名参数不会下发
uci set dhcp.@dnsmasq[0].dnsforwardmax='10000' 2>/dev/null
uci commit dhcp 2>/dev/null
log "  dnsmasq dnsforwardmax=10000"

# P0-2: UDP 收发缓冲下限 4096 → 131072（防高并发 DNS 丢包）
# P2:   预留 DNS/服务端口，防临时端口撞车
cat > /etc/sysctl.d/99-dns-tuning.conf <<'SYSEOF'
# openclash-mosdns-kit: DNS 高并发 UDP 缓冲（防丢包）
net.ipv4.udp_rmem_min = 131072
net.ipv4.udp_wmem_min = 131072
# 预留 DNS/服务端口，防被临时端口占用
net.ipv4.ip_local_reserved_ports = 53,5350
SYSEOF
sysctl -p /etc/sysctl.d/99-dns-tuning.conf >/dev/null 2>&1
log "  UDP 缓冲 131072 + 端口预留已生效"

# P1-2: THP 改 madvise（降 DNS 这类小内存低延迟进程的 GC 抖动）
if [ -w /sys/kernel/mm/transparent_hugepage/enabled ]; then
    echo madvise > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null
    if [ -f /etc/rc.local ] && ! grep -q transparent_hugepage /etc/rc.local 2>/dev/null; then
        # 插到 exit 0 之前
        if grep -q '^exit 0' /etc/rc.local; then
            sed -i 's|^exit 0|echo madvise > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null\nexit 0|' /etc/rc.local
        else
            echo 'echo madvise > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null' >> /etc/rc.local
        fi
        chmod +x /etc/rc.local 2>/dev/null
    fi
    log "  THP → madvise（已持久化 rc.local）"
fi

# ---------------------------------------------------------------------------
# 7A. 接管路径：OpenClash 已启用
# ---------------------------------------------------------------------------
takeover_openclash() {
    # 自动探测订阅域名（防 DNS↔代理死锁）
    # 说明：OpenClash 要 HTTP 拉订阅、要连代理节点。真正必须"直连解析"的是
    #       订阅地址的 host（否则拉订阅这一步就卡住）。代理节点 server 域名
    #       走 mosdns 境外序列拿真实 IP 即可，解析本身不经代理，不会死锁。
    log "探测订阅地址 host（这些直连解析，防死锁）..."
    PROXY_HOSTS=""
    idx=0
    while true; do
        addr=$(uci get openclash.@config_subscribe[${idx}].address 2>/dev/null) || break
        [ -z "$addr" ] && break
        h=$(echo "$addr" | sed -E 's#https?://##; s#/.*##; s#:[0-9]+$##')
        PROXY_HOSTS="$PROXY_HOSTS $h"
        idx=$((idx+1))
    done
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
    [ $first -eq 1 ] && NSP="{}"

    log "写 OpenClash DNS 接管钩子..."
    write_takeover_hook "$NSP"
    log "钩子已写入 $OCC_HOOK"

    # 有 VPS 时放行 VPS 流量（防 DoT 被 TUN 劫持成环）
    write_vps_bypass

    # 保持 fake-ip：国外域名由 OpenClash 秒回假地址、代理节点真解析（干净且稳），
    # mosdns 只负责加速 fake-ip-filter 放行回源的国内域名。
    # 不切 redir-host —— 实测境内裸连境外 DoH 不稳定，redir-host 会把国外解析
    # 押在境外 DoH 上，偶发解析失败。fake-ip 模式彻底规避这一点。
    CUR_MODE="$(uci get openclash.config.en_mode 2>/dev/null || echo unknown)"
    if [ "$CUR_MODE" = "redir-host" ]; then
        log "当前为 redir-host，切回 fake-ip（国外走代理解析，更稳）..."
        uci set openclash.config.en_mode='fake-ip' 2>/dev/null
        uci set openclash.config.operation_mode='fake-ip' 2>/dev/null
        uci commit openclash 2>/dev/null
    else
        log "保持 fake-ip 模式（国外域名走代理节点解析，不依赖境外 DoH）..."
    fi

    log "重启 OpenClash（约 5-10 秒网络抖动）..."
    /etc/init.d/openclash restart 2>/dev/null
    sleep 8
}

# ---------------------------------------------------------------------------
# 7B. 接管路径：无（或未启用）OpenClash → 直接接管 dnsmasq
# ---------------------------------------------------------------------------
takeover_dnsmasq() {
    log "把 dnsmasq 上游指向 mosdns（dnsmasq 保留，继续管 DHCP 与本地主机名）..."

    # 清掉原有 server 列表，只留 mosdns（uci set 会整体替换该 list）
    uci set dhcp.@dnsmasq[0].server="127.0.0.1#5350" || die "uci 设置 dnsmasq server 失败"
    # 缓存统一交给 mosdns，避免两层缓存叠加导致改配置后旧答案赖着不走
    uci set dhcp.@dnsmasq[0].cachesize='0'
    # 忽略 WAN 口 DHCP 下发的 resolv.conf，防止运营商 DNS 偷偷插回来
    uci set dhcp.@dnsmasq[0].noresolv='1'
    uci commit dhcp || die "uci commit dhcp 失败"
    log "dnsmasq 上游 → 127.0.0.1#5350，cachesize=0，noresolv=1"

    # 顺手关掉 IPv6 DNS 干扰：很多"DNS 慢"其实是 IPv6 DNS 不可达在空等
    if uci show network.wan6 >/dev/null 2>&1; then
        uci set network.wan6.peerdns='0' 2>/dev/null
        uci commit network 2>/dev/null
        log "已关闭 wan6 的 peerdns（防 IPv6 DNS 空等）"
    fi

    # 可选：nftables 劫持，把局域网里写死第三方 DNS 的设备也拽回来
    if [ "$HIJACK_LAN_DNS" = "1" ]; then
        command -v nft >/dev/null 2>&1 || die "HIJACK_LAN_DNS=1 需要 nft（opkg install nftables）"
        log "追加 nftables 劫持规则（局域网 53 → mosdns:5350，接口 $LAN_IF）..."
        nft add table inet mosdnshijack 2>/dev/null
        nft add chain inet mosdnshijack prerouting '{ type nat hook prerouting priority dstnat ; policy accept ; }' 2>/dev/null
        nft add rule inet mosdnshijack prerouting iifname "$LAN_IF" udp dport 53 redirect to :5350 2>/dev/null
        nft add rule inet mosdnshijack prerouting iifname "$LAN_IF" tcp dport 53 redirect to :5350 2>/dev/null
        # 持久化：开机加载
        mkdir -p /etc/nftables.d 2>/dev/null
        cat > /etc/nftables.d/mosdnshijack.nft <<NFTEOF
table inet mosdnshijack {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        iifname "$LAN_IF" udp dport 53 redirect to :5350
        iifname "$LAN_IF" tcp dport 53 redirect to :5350
    }
}
NFTEOF
        log "劫持规则已生效并持久化到 /etc/nftables.d/mosdnshijack.nft"
    else
        log "未开启局域网劫持（需要时加环境变量 HIJACK_LAN_DNS=1 重装）"
    fi

    log "重启 dnsmasq..."
    /etc/init.d/dnsmasq restart 2>/dev/null
    sleep 3
}

log "执行接管（模式: $KIT_MODE）..."
if [ "$KIT_MODE" = "openclash" ]; then
    takeover_openclash
else
    takeover_dnsmasq
    if [ "$HAS_OC" = "1" ]; then
        log "预写 OpenClash 钩子（当前未启用，启用后自动接管）..."
        write_takeover_hook ""
    fi
fi

# 记录本次接管模式，供 uninstall 判断
{
    echo "mode=$KIT_MODE"
    echo "has_openclash=$HAS_OC"
    echo "hijack=$HIJACK_LAN_DNS"
    echo "listen=$MOSDNS_LISTEN"
    echo "vps_ip=$VPS_IP"
    echo "installed_at=$(date '+%F %T')"
} > "$MODE_FILE" 2>/dev/null
log "接管模式已记录: $MODE_FILE"

# ---------------------------------------------------------------------------
# 8. 部署每日规则表同步（保持 CN 网段表持续更新）
# ---------------------------------------------------------------------------
log "部署每日规则表同步脚本..."
SYNC_SCRIPT="/root/mosdns-rule-sync.sh"
cat > "$SYNC_SCRIPT" <<SYNCEOF
#!/bin/sh
# mosdns CN 网段表每日同步（自动维护，勿手改）
set -u
INSTALL_DIR="/etc/mosdns"
IP_TABLE="\$INSTALL_DIR/IPchnroute"
LOG="/var/log/mosdns-sync.log"
SRC_IP="${GH_PROXY}https://raw.githubusercontent.com/herman6888/openclash-mosdns-kit/main/data/IPchnroute"
MIN_IP=5000
log() { echo "[\$(date '+%F %T')] \$*" >> "\$LOG"; }
TMP_IP="/tmp/sync_IP.\$\$.tmp"
trap 'rm -f "\$TMP_IP"' EXIT
fetch() { if command -v curl >/dev/null 2>&1; then curl -fsSL --max-time 40 "\$1" -o "\$2"; else wget -q -T 40 "\$1" -O "\$2"; fi; }
log "=== 同步开始 ==="
fetch "\$SRC_IP" "\$TMP_IP" || { log "✗ IP 表下载失败，保留旧表"; exit 1; }
IP_N=\$(wc -l < "\$TMP_IP" 2>/dev/null || echo 0)
[ "\$IP_N" -ge "\$MIN_IP" ] || { log "✗ IP 表行数异常(\$IP_N)，拒绝替换"; exit 1; }
BAD_IP=\$(grep -cvE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+\$' "\$TMP_IP" 2>/dev/null || true)
BLANK=\$(grep -cE '^[[:space:]]*\$' "\$TMP_IP" 2>/dev/null || true)
[ \$((BAD_IP - BLANK)) -le 0 ] || { log "✗ IP 表含非规范行，拒绝替换"; exit 1; }
if [ -f "\$IP_TABLE" ] && cmp -s "\$TMP_IP" "\$IP_TABLE"; then
    log "无变化(IP=\$IP_N)，跳过"; exit 0; fi
STAMP=\$(date +%Y%m%d-%H%M%S)
[ -f "\$IP_TABLE" ] && cp -a "\$IP_TABLE" "\$IP_TABLE.bak-\$STAMP"
mv -f "\$TMP_IP" "\$IP_TABLE"; trap - EXIT
/etc/init.d/mosdns restart 2>>"\$LOG"; sleep 2
if pidof mosdns >/dev/null 2>&1; then
    log "✓ 同步完成 IP=\$IP_N"; find "\$INSTALL_DIR" -name '*.bak-*' -mtime +7 -delete 2>/dev/null; exit 0
else
    log "✗ 重启失败，回滚"; cp -a "\$IP_TABLE.bak-\$STAMP" "\$IP_TABLE" 2>/dev/null; /etc/init.d/mosdns restart 2>>"\$LOG"; exit 1
fi
SYNCEOF
chmod +x "$SYNC_SCRIPT"
# 加每日 cron（幂等，避开常见整点）
( crontab -l 2>/dev/null | grep -v "mosdns-rule-sync"
  echo "30 3 * * * /bin/sh $SYNC_SCRIPT # mosdns-rule-sync" ) | crontab - 2>/dev/null
log "每日同步已部署：$SYNC_SCRIPT（cron 03:30）"

# ---------------------------------------------------------------------------
# 9. 验证
# ---------------------------------------------------------------------------
log "验证..."
FAIL=0
pidof mosdns >/dev/null 2>&1 || { log "✗ mosdns 未运行"; FAIL=1; }
if [ "$KIT_MODE" = "openclash" ]; then
    pidof clash >/dev/null 2>&1 || { log "✗ clash 未运行"; FAIL=1; }
else
    pidof dnsmasq >/dev/null 2>&1 || { log "✗ dnsmasq 未运行"; FAIL=1; }
fi
# dnsmasq 参数落地检查（dnsforwardmax 名字写错会静默无效，必须查生成文件）
if grep -q "dns-forward-max=10000" /var/etc/dnsmasq.conf.* 2>/dev/null; then
    log "✓ dnsmasq dns-forward-max=10000 已下发"
else
    log "⚠ dnsmasq dns-forward-max 未见下发（检查 /var/etc/dnsmasq.conf.*）"
fi
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
    log "✅ 安装完成！（接管模式: $KIT_MODE）"
    log "  mosdns: $(pidof mosdns)  监听 $MOSDNS_LISTEN"
    if [ "$KIT_MODE" = "openclash" ]; then
        log "  OpenClash: fake-ip（国外走代理解析）+ mosdns 加速国内"
        [ -n "$VPS_IP" ] && log "  境外兜底: 自建 VPS DoT ($VPS_IP:853)"
    else
        log "  dnsmasq: 上游 → mosdns，缓存已交给 mosdns"
        [ "$HIJACK_LAN_DNS" = "1" ] && log "  nftables: 局域网 53 已劫持到 mosdns"
    fi
    log "  内核调优: UDP 缓冲 / THP / nice=-11 / 端口预留"
    log "  备份: $BACKUP_DIR"
    log "  卸载: sh uninstall.sh"
    log "============================================"
else
    log "⚠ 安装可能未完全成功，请检查日志：/var/log/mosdns.log"
    log "  回滚：cp $BACKUP_DIR/*.bak 还原 + sh uninstall.sh"
    exit 1
fi
