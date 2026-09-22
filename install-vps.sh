#!/bin/sh
# ============================================================================
#  openclash-mosdns-kit — 一键安装（自建 VPS 加密 DNS 版）
#
#  在「无 VPS 版」的基础上，把境外兜底解析换成你自己 VPS 上的 DoT：
#  境外域名的解析请求全程加密出户，不经过任何第三方 DNS。
#
#  硬性前提（本脚本会逐条校验，不满足直接退出，不会改你任何配置）：
#    1. 已安装并【启用】OpenClash
#    2. OpenClash 已配好订阅（能拉到节点）
#    3. VPS 上已部署好 DoT 服务端（见 scripts/vps-server.sh）
#
#  用法：
#    VPS_IP=你的VPS地址 sh install-vps.sh
#    或：sh install-vps.sh 你的VPS地址
#
#  卸载：sh uninstall.sh（与无 VPS 版通用）
#
#  安全声明：本脚本只改 DNS 路径，不碰代理节点/订阅/出口规则。
#           改前自动备份，可随时 uninstall 回滚。
# ============================================================================
set -u

VPS_IP="${VPS_IP:-${1:-}}"

log()  { echo "[install-vps] $*"; }
die()  { echo "[install-vps][ERROR] $*" >&2; exit 1; }
hint() { echo "  → $*" >&2; }

# ---------------------------------------------------------------------------
# 0. 基础检查
# ---------------------------------------------------------------------------
[ "$(id -u)" = "0" ] || die "需要 root 运行"
command -v uci >/dev/null 2>&1 || die "找不到 uci，这不是 OpenWrt/iStoreOS？"

if [ -z "$VPS_IP" ]; then
    die "必须指定 VPS 地址：VPS_IP=1.2.3.4 sh install-vps.sh（或 sh install-vps.sh 1.2.3.4）"
fi
# 简单格式校验（IPv4 或域名）
echo "$VPS_IP" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$|^[A-Za-z0-9.-]+$' \
    || die "VPS 地址格式不对：$VPS_IP"

# ---------------------------------------------------------------------------
# 1. 硬性前提校验：OpenClash 必须已装且已启用
# ---------------------------------------------------------------------------
HAS_OC=0
[ -d /etc/openclash ] && [ -f /etc/init.d/openclash ] && HAS_OC=1
OC_ENABLED="$(uci get openclash.config.enable 2>/dev/null || true)"

if [ "$HAS_OC" != "1" ]; then
    echo "" >&2
    echo "❌ 未检测到 OpenClash。自建 VPS 加密 DNS 模式必须配合 OpenClash 使用。" >&2
    hint "1) 在 iStore/软件中心安装 OpenClash（或 opkg 安装）" >&2
    hint "2) 导入你的订阅并启用，确认代理可用" >&2
    hint "3) 再回来跑：VPS_IP=$VPS_IP sh install-vps.sh" >&2
    echo "" >&2
    echo "只想优化 DNS、不用代理？请改用无 VPS 版：sh install.sh" >&2
    exit 2
fi

if [ "$OC_ENABLED" != "1" ]; then
    echo "" >&2
    echo "❌ OpenClash 已安装但未启用（openclash.config.enable=$OC_ENABLED）。" >&2
    hint "先在 OpenClash 面板启用它，确认节点能正常上网，再跑本脚本。" >&2
    hint "检查命令：uci get openclash.config.enable" >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# 2. 硬性前提校验：订阅必须已配置
# ---------------------------------------------------------------------------
SUB_OK=0
idx=0
while true; do
    addr=$(uci get openclash.@config_subscribe[${idx}].address 2>/dev/null) || break
    [ -n "$addr" ] && SUB_OK=1 && break
    idx=$((idx+1))
done
# 兼容：有些配置直接用本地配置文件而非在线订阅
if [ "$SUB_OK" != "1" ]; then
    for f in /etc/openclash/config.yaml /etc/openclash/*.yaml; do
        [ -f "$f" ] && SUB_OK=1 && break
    done
fi

if [ "$SUB_OK" != "1" ]; then
    echo "" >&2
    echo "❌ 未检测到已配置的订阅（config_subscribe 为空，也没有本地配置文件）。" >&2
    hint "1) OpenClash → 配置管理 → 订阅设置，填入你的机场订阅地址并更新" >&2
    hint "2) 确认「Override Settings」里没有把 DNS 改成别的方案（会与本脚本冲突）" >&2
    hint "3) 代理能正常上网后，再跑：VPS_IP=$VPS_IP sh install-vps.sh" >&2
    exit 2
fi
log "✓ OpenClash 已启用，订阅已配置"

# ---------------------------------------------------------------------------
# 3. VPS DoT 连通性预检（不通过就退出，避免装完才发现连不上）
# ---------------------------------------------------------------------------
log "预检 VPS DoT 连通性（$VPS_IP:853）..."
DOT_OK=0
# BusyBox 无 timeout/nc -z，用后台进程 + 看门狗实现限时探测
probe() {
    # $@ = 要跑的探测命令；15 秒内没结束就杀掉
    "$@" >/tmp/dot_probe.out 2>&1 &
    PID=$!
    i=0
    while [ $i -lt 15 ]; do
        kill -0 "$PID" 2>/dev/null || break
        sleep 1; i=$((i+1))
    done
    kill -9 "$PID" 2>/dev/null
    wait "$PID" 2>/dev/null
}
if command -v openssl >/dev/null 2>&1; then
    # 自签证书校验必然失败，这里只看 TCP+TLS 握手是否建立（CONNECTED 出现即通）
    probe sh -c "echo | openssl s_client -connect ${VPS_IP}:853"
    grep -q "CONNECTED" /tmp/dot_probe.out 2>/dev/null && DOT_OK=1
elif command -v nc >/dev/null 2>&1; then
    probe sh -c "echo </dev/null | nc ${VPS_IP} 853"
    # nc 无输出也算连上（端口开着）——用退出码不可靠，改查连接是否被拒
    grep -qiE "refused|unreachable|timed out" /tmp/dot_probe.out 2>/dev/null || DOT_OK=1
else
    log "⚠ 系统无 openssl/nc，跳过预检（安装后会用真实查询验证）"
    DOT_OK=1
fi
rm -f /tmp/dot_probe.out

if [ "$DOT_OK" != "1" ]; then
    echo "" >&2
    echo "❌ 连不上 $VPS_IP:853（DoT）。" >&2
    hint "1) VPS 上确认 mosdns 服务在跑：systemctl status mosdns" >&2
    hint "2) VPS 防火墙放行 853/tcp，且把你家当前出口 IP 加进白名单" >&2
    hint "   （家宽 PPPPoE 重拨后出口 IP 会变，这是最常见的连不上原因）" >&2
    hint "3) 手动验证：openssl s_client -connect $VPS_IP:853" >&2
    hint "4) 通了以后再跑本脚本" >&2
    exit 2
fi
log "✓ VPS DoT 可达"

# ---------------------------------------------------------------------------
# 4. 移交 install.sh（注入 VPS_IP，复用同一套安装/接管/调优逻辑）
# ---------------------------------------------------------------------------
SELF_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd || echo /tmp)"
INSTALLER="$SELF_DIR/install.sh"

if [ ! -f "$INSTALLER" ]; then
    log "本地未找到 install.sh，尝试下载..."
    GH_PROXY="${GH_PROXY:-}"
    fetch() {
        if command -v curl >/dev/null 2>&1; then curl -fsSL --max-time 60 "$1" -o "$2"
        elif command -v wget >/dev/null 2>&1; then wget -q -T 60 "$1" -O "$2"
        else return 1; fi
    }
    DL="https://raw.githubusercontent.com/herman6888/openclash-mosdns-kit/main/install.sh"
    OK=0
    for pre in "${GH_PROXY}" "" "https://gh-proxy.com/" "https://ghfast.top/"; do
        fetch "${pre}${DL}" /tmp/install.sh && [ -s /tmp/install.sh ] && OK=1 && break
    done
    [ "$OK" = "1" ] || die "install.sh 下载失败，请把 install.sh 和本脚本放在同一目录再跑"
    INSTALLER=/tmp/install.sh
fi

log "开始安装（境外兜底 → tls://$VPS_IP:853）..."
VPS_IP="$VPS_IP" sh "$INSTALLER"
RC=$?

if [ "$RC" = "0" ]; then
    log "============================================"
    log "✅ VPS 模式安装完成"
    log "  国内域名：5 路竞速 + CN 网段校验（~10ms）"
    log "  境外域名：加密走你的 VPS DoT（$VPS_IP:853）"
    log "  防环路：VPS 流量已在 OpenClash 防火墙放行"
    log "  卸载：sh uninstall.sh"
    log "============================================"
    log "提示：家宽重拨后若境外解析变慢/超时，先到 VPS 更新白名单里的出口 IP。"
else
    die "安装失败（exit=$RC），查 /var/log/mosdns.log 与备份目录回滚"
fi
