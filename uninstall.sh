#!/bin/sh
# ============================================================================
#  openclash-mosdns-kit — 卸载
#  移除 mosdns 接管，恢复 OpenClash 原样（用安装时的备份还原）
#
#  用法：  sh uninstall.sh
# ============================================================================
set -u

log() { echo "[uninstall] $*"; }

[ "$(id -u)" = "0" ] || { echo "[uninstall][ERROR] 需要 root" >&2; exit 1; }

OCC_HOOK="/etc/openclash/custom/openclash_custom_overwrite.sh"
BACKUP_ROOT="/root"

# 找最近一次安装备份
LATEST_BACKUP=$(ls -d "$BACKUP_ROOT"/openclash-mosdns-kit-backup-* 2>/dev/null | sort | tail -1)

# 1. 停 mosdns
log "停止 mosdns 服务..."
if [ -f /etc/init.d/mosdns ]; then
    /etc/init.d/mosdns stop 2>/dev/null
    /etc/init.d/mosdns disable 2>/dev/null
fi

# 2. 还原 OpenClash 钩子
if [ -n "$LATEST_BACKUP" ] && [ -f "$LATEST_BACKUP/openclash_custom_overwrite.sh.bak" ]; then
    log "从备份还原 OpenClash 钩子: $LATEST_BACKUP"
    cp -a "$LATEST_BACKUP/openclash_custom_overwrite.sh.bak" "$OCC_HOOK"
elif [ -f "$OCC_HOOK" ]; then
    log "无备份，仅移除 kit 注入的段..."
    sed -i '/# >>> openclash-mosdns-kit/,/# <<< openclash-mosdns-kit/d' "$OCC_HOOK"
fi

# 3. 还原 openclash UCI（redir-host → 原值）
if [ -n "$LATEST_BACKUP" ] && [ -f "$LATEST_BACKUP/openclash.uci.bak" ]; then
    log "提示：openclash UCI 备份在 $LATEST_BACKUP/openclash.uci.bak"
    log "      如需精确还原 redir-host 设置，请手动比对后 uci import 或逐项 set。"
    # 保守起见只把 en_mode 改回 fake-ip（多数原配置默认值）
    uci set openclash.config.en_mode='fake-ip' 2>/dev/null
    uci set openclash.config.operation_mode='fake-ip' 2>/dev/null
    uci commit openclash 2>/dev/null
fi

# 4. 删 mosdns 文件
log "删除 mosdns 二进制与配置..."
rm -f /usr/bin/mosdns /etc/init.d/mosdns
rm -rf /etc/mosdns
rm -f /var/log/mosdns.log

# 5. 重启 OpenClash
log "重启 OpenClash 生效（5-10 秒抖动）..."
/etc/init.d/openclash restart 2>/dev/null
sleep 6

log "============================================"
log "✅ 卸载完成。mosdns 已移除，OpenClash 恢复接管 DNS。"
if [ -n "$LATEST_BACKUP" ]; then
    log "   备份保留在: $LATEST_BACKUP（确认无误后可手动删除）"
fi
log "============================================"
