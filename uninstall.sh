#!/bin/sh
# ============================================================================
#  openclash-mosdns-kit — 卸载
#  移除 mosdns 接管，恢复安装前状态（自动识别安装模式）
#
#  用法：  sh uninstall.sh
# ============================================================================
set -u

log() { echo "[uninstall] $*"; }

[ "$(id -u)" = "0" ] || { echo "[uninstall][ERROR] 需要 root" >&2; exit 1; }

OCC_HOOK="/etc/openclash/custom/openclash_custom_overwrite.sh"
MODE_FILE="/etc/mosdns/.kit-mode"
BACKUP_ROOT="/root"

# 读安装时记录的模式
KIT_MODE="openclash"
HIJACK="0"
if [ -f "$MODE_FILE" ]; then
    KIT_MODE=$(grep -m1 '^mode=' "$MODE_FILE" 2>/dev/null | cut -d= -f2)
    HIJACK=$(grep -m1 '^hijack=' "$MODE_FILE" 2>/dev/null | cut -d= -f2)
    [ -n "$KIT_MODE" ] || KIT_MODE="openclash"
fi
log "识别到安装模式: $KIT_MODE（劫持=$HIJACK）"

# 找最近一次安装备份
LATEST_BACKUP=$(ls -d "$BACKUP_ROOT"/openclash-mosdns-kit-backup-* 2>/dev/null | sort | tail -1)

# 1. 停 mosdns
log "停止 mosdns 服务..."
if [ -f /etc/init.d/mosdns ]; then
    /etc/init.d/mosdns stop 2>/dev/null
    /etc/init.d/mosdns disable 2>/dev/null
fi

# 2. 移除 nftables 劫持（若有）
if command -v nft >/dev/null 2>&1 && nft list table inet mosdnshijack >/dev/null 2>&1; then
    log "删除 nftables 劫持表..."
    nft delete table inet mosdnshijack 2>/dev/null
fi
rm -f /etc/nftables.d/mosdnshijack.nft 2>/dev/null

# 3. 还原 dnsmasq / dhcp（dnsmasq 模式，或任何模式下 dhcp 被改过）
if [ -n "$LATEST_BACKUP" ] && [ -f "$LATEST_BACKUP/dhcp.bak" ]; then
    log "从备份还原 /etc/config/dhcp ..."
    cp -a "$LATEST_BACKUP/dhcp.bak" /etc/config/dhcp
    /etc/init.d/dnsmasq restart 2>/dev/null
    sleep 2
    log "dnsmasq 已还原并重启"
elif [ "$KIT_MODE" = "dnsmasq" ]; then
    log "无 dhcp 备份，改为把 dnsmasq 上游指回公共 DNS..."
    uci set dhcp.@dnsmasq[0].server='119.29.29.29' 2>/dev/null
    uci add_list dhcp.@dnsmasq[0].server='223.5.5.5' 2>/dev/null
    uci set dhcp.@dnsmasq[0].cachesize='4096' 2>/dev/null
    uci commit dhcp 2>/dev/null
    /etc/init.d/dnsmasq restart 2>/dev/null
    sleep 2
fi

# 4. 还原 OpenClash 钩子
if [ -n "$LATEST_BACKUP" ] && [ -f "$LATEST_BACKUP/openclash_custom_overwrite.sh.bak" ]; then
    log "从备份还原 OpenClash 钩子: $LATEST_BACKUP"
    cp -a "$LATEST_BACKUP/openclash_custom_overwrite.sh.bak" "$OCC_HOOK"
elif [ -f "$OCC_HOOK" ]; then
    log "无备份，仅移除 kit 注入的段..."
    sed -i '/# >>> openclash-mosdns-kit/,/# <<< openclash-mosdns-kit/d' "$OCC_HOOK"
fi

# 5. 还原 openclash UCI（redir-host → 原值）
if [ "$KIT_MODE" = "openclash" ] && [ -n "$LATEST_BACKUP" ] && [ -f "$LATEST_BACKUP/openclash.uci.bak" ]; then
    log "提示：openclash UCI 备份在 $LATEST_BACKUP/openclash.uci.bak"
    log "      如需精确还原 redir-host 设置，请手动比对后 uci import 或逐项 set。"
    # 保守起见只把 en_mode 改回 fake-ip（多数原配置默认值）
    uci set openclash.config.en_mode='fake-ip' 2>/dev/null
    uci set openclash.config.operation_mode='fake-ip' 2>/dev/null
    uci commit openclash 2>/dev/null
fi

# 6. 删 mosdns 文件
log "删除 mosdns 二进制与配置..."
rm -f /usr/bin/mosdns /etc/init.d/mosdns
rm -rf /etc/mosdns
rm -f /var/log/mosdns.log

# 7. 重启相关服务
if [ "$KIT_MODE" = "openclash" ] && [ -f /etc/init.d/openclash ]; then
    log "重启 OpenClash 生效（5-10 秒抖动）..."
    /etc/init.d/openclash restart 2>/dev/null
    sleep 6
fi

log "============================================"
log "✅ 卸载完成。mosdns 已移除，DNS 路径已还原。"
if [ -n "$LATEST_BACKUP" ]; then
    log "   备份保留在: $LATEST_BACKUP（确认无误后可手动删除）"
fi
log "============================================"
