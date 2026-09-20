#!/bin/sh
# ============================================================================
#  openclash-mosdns-kit — 一键安装
#  给路由器加一层 mosdns：国内并发竞速 + resp_ip 防污染 + 本地缓存
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
# 兜底上游（非国内域名用）—— 按接管模式区分，见下方赋值
# 架构说明：
#   OpenClash 模式：国外域名由 OpenClash fake-ip 秒回假地址、代理节点真解析（干净且稳），
#     mosdns 只加速 fake-ip-filter 放行回源的国内域名。兜底用国内 DNS 快速应答即可，
#     彻底不碰境外 DoH —— 实测境内裸连境外 DoH 间歇 TLS 超时，押它会偶发解析失败。
#   dnsmasq 模式（无代理）：国外域名没有代理可走，境外 DoH 是唯一出路，必须保留。
# ⚠ 实测教训：阿里/腾讯 DoH 是【境内】节点，对境外被墙域名返回污染答案，不能当境外上游。
BAK_UP1=""   # 在模式检测后按 KIT_MODE 赋值
BAK_UP2=""
BAK_BOOT1="223.5.5.5"
BAK_BOOT2="223.5.5.5"
# 规则表源（CN 网段/域名分流表，每日自动更新）
RULE_BASE="https://raw.githubusercontent.com/herman6888/openclash-mosdns-kit/main/data"
# GitHub 加速前缀（国内访问 raw.githubusercontent 受阻时改成 https://gh-proxy.com/）
GH_PROXY="${GH_PROXY:-}"
# 竞速阈值(ms)
RACE_THRESHOLD="100"
# 是否劫持局域网 53 端口（仅无 OpenClash 模式有意义）
HIJACK_LAN_DNS="${HIJACK_LAN_DNS:-0}"
LAN_IF="${LAN_IF:-br-lan}"

INSTALL_DIR="/etc/mosdns"
BIN="/usr/bin/mosdns"
INIT="/etc/init.d/mosdns"
OCC_DIR="/etc/openclash/custom"
OCC_HOOK="$OCC_DIR/openclash_custom_overwrite.sh"
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

# 安全写入 OpenClash 接管钩子。
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
    # 国外走 fake-ip+代理，mosdns 兜底用国内 DNS（不押境外 DoH）
    BAK_UP1="223.5.5.5:53"
    BAK_UP2="119.29.29.29:53"
else
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
[ "$HAS_OC" = "1" ] && uci show openclash > "$BACKUP_DIR/openclash.uci.bak" 2>/dev/null && log "已备份 openclash UCI"
# dnsmasq / dhcp 配置备份（两种模式都备，回滚用）
cp -a /etc/config/dhcp "$BACKUP_DIR/dhcp.bak" 2>/dev/null && log "已备份 /etc/config/dhcp"
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
# 4. 下载分流规则表
# ---------------------------------------------------------------------------
log "下载分流规则表（IPchnroute + Domains.chn.txt）..."
for f in "IPchnroute" "Domains.chn.txt"; do
    out="$INSTALL_DIR/$(basename "$f")"
    fetch "${GH_PROXY}${RULE_BASE}/${f}" "$out" || die "规则表下载失败: $f"
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
        - addr: ${BAK_UP1}
          bootstrap: "${BAK_BOOT1}"
        - addr: ${BAK_UP2}
          bootstrap: "${BAK_BOOT2}"

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

  # 兜底序列：非国内域名（fake-ip 模式下极少走到这里），国内 DNS 快速应答
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
    # OpenClash 装了但当前未启用时，也预写钩子，日后启用自动接上
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
    echo "installed_at=$(date '+%F %T')"
} > "$MODE_FILE" 2>/dev/null
log "接管模式已记录: $MODE_FILE"

# ---------------------------------------------------------------------------
# 8. 部署每日规则表同步（保持 CN 分流表持续更新）
# ---------------------------------------------------------------------------
log "部署每日规则表同步脚本..."
SYNC_SCRIPT="/root/mosdns-rule-sync.sh"
cat > "$SYNC_SCRIPT" <<SYNCEOF
#!/bin/sh
# mosdns 分流规则表每日同步（自动维护，勿手改）
set -u
INSTALL_DIR="/etc/mosdns"
IP_TABLE="\$INSTALL_DIR/IPchnroute"
DOM_TABLE="\$INSTALL_DIR/Domains.chn.txt"
LOG="/var/log/mosdns-sync.log"
SRC_IP="${GH_PROXY}https://raw.githubusercontent.com/herman6888/openclash-mosdns-kit/main/data/IPchnroute"
SRC_DOM="${GH_PROXY}https://raw.githubusercontent.com/herman6888/openclash-mosdns-kit/main/data/Domains.chn.txt"
MIN_IP=5000; MIN_DOM=50000
log() { echo "[\$(date '+%F %T')] \$*" >> "\$LOG"; }
TMP_IP="/tmp/sync_IP.\$\$.tmp"; TMP_DOM="/tmp/sync_DOM.\$\$.tmp"
trap 'rm -f "\$TMP_IP" "\$TMP_DOM"' EXIT
fetch() { if command -v curl >/dev/null 2>&1; then curl -fsSL --max-time 40 "\$1" -o "\$2"; else wget -q -T 40 "\$1" -O "\$2"; fi; }
log "=== 同步开始 ==="
fetch "\$SRC_IP" "\$TMP_IP" || { log "✗ IP 表下载失败，保留旧表"; exit 1; }
fetch "\$SRC_DOM" "\$TMP_DOM" || { log "✗ 域名表下载失败，保留旧表"; exit 1; }
IP_N=\$(wc -l < "\$TMP_IP" 2>/dev/null || echo 0); DOM_N=\$(wc -l < "\$TMP_DOM" 2>/dev/null || echo 0)
[ "\$IP_N" -ge "\$MIN_IP" ] || { log "✗ IP 表行数异常(\$IP_N)，拒绝替换"; exit 1; }
[ "\$DOM_N" -ge "\$MIN_DOM" ] || { log "✗ 域名表行数异常(\$DOM_N)，拒绝替换"; exit 1; }
BAD_IP=\$(grep -cvE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+\$' "\$TMP_IP" 2>/dev/null || true)
BLANK=\$(grep -cE '^[[:space:]]*\$' "\$TMP_IP" 2>/dev/null || true)
[ \$((BAD_IP - BLANK)) -le 0 ] || { log "✗ IP 表含非规范行，拒绝替换"; exit 1; }
if [ -f "\$IP_TABLE" ] && cmp -s "\$TMP_IP" "\$IP_TABLE" && [ -f "\$DOM_TABLE" ] && cmp -s "\$TMP_DOM" "\$DOM_TABLE"; then
    log "无变化(IP=\$IP_N DOM=\$DOM_N)，跳过"; exit 0; fi
STAMP=\$(date +%Y%m%d-%H%M%S)
[ -f "\$IP_TABLE" ] && cp -a "\$IP_TABLE" "\$IP_TABLE.bak-\$STAMP"
[ -f "\$DOM_TABLE" ] && cp -a "\$DOM_TABLE" "\$DOM_TABLE.bak-\$STAMP"
mv -f "\$TMP_IP" "\$IP_TABLE"; mv -f "\$TMP_DOM" "\$DOM_TABLE"; trap - EXIT
/etc/init.d/mosdns restart 2>>"\$LOG"; sleep 2
if pidof mosdns >/dev/null 2>&1; then
    log "✓ 同步完成 IP=\$IP_N 域名=\$DOM_N"; find "\$INSTALL_DIR" -name '*.bak-*' -mtime +7 -delete 2>/dev/null; exit 0
else
    log "✗ 重启失败，回滚"; cp -a "\$IP_TABLE.bak-\$STAMP" "\$IP_TABLE" 2>/dev/null; cp -a "\$DOM_TABLE.bak-\$STAMP" "\$DOM_TABLE" 2>/dev/null; /etc/init.d/mosdns restart 2>>"\$LOG"; exit 1
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
    else
        log "  dnsmasq: 上游 → mosdns，缓存已交给 mosdns"
        [ "$HIJACK_LAN_DNS" = "1" ] && log "  nftables: 局域网 53 已劫持到 mosdns"
    fi
    log "  备份: $BACKUP_DIR"
    log "  卸载: sh uninstall.sh"
    log "============================================"
else
    log "⚠ 安装可能未完全成功，请检查日志：/var/log/mosdns.log"
    log "  回滚：cp $BACKUP_DIR/*.bak 还原 + sh uninstall.sh"
    exit 1
fi
