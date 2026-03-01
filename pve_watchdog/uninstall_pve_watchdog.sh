#!/bin/bash
# ============================================================
# PVE 网络守卫 - 完全卸载脚本
# ============================================================

SCRIPT_DEST="/usr/local/bin/pve_watchdog.sh"
LOG_FILE="/var/log/pve_watchdog.log"
SERVICE_FILE="/etc/systemd/system/pve-watchdog.service"
COOLDOWN_TS="/var/run/pve_watchdog_last_reboot.ts"

echo "=========================================================="
echo "         PVE 网络守卫 - 完全卸载"
echo "=========================================================="

# 1. 停止并禁用服务
echo "[1/4] 停止并禁用 systemd 服务..."
systemctl stop pve-watchdog.service 2>/dev/null
systemctl disable pve-watchdog.service 2>/dev/null
echo "  -> 服务已停止"

# 2. 删除 systemd 服务文件并重载
echo "[2/4] 删除 systemd 服务文件..."
rm -f "$SERVICE_FILE"
systemctl daemon-reload
systemctl reset-failed 2>/dev/null
echo "  -> 服务文件已清除"

# 3. 删除所有相关文件
echo "[3/4] 清除所有脚本、日志及运行时文件..."
rm -f "$SCRIPT_DEST"
rm -f "$LOG_FILE"
rm -f "$COOLDOWN_TS"
echo "  -> 文件已全部删除"

# 4. 确认无残留进程
echo "[4/4] 检查并清理残留进程..."
PIDS=$(pgrep -f "pve_watchdog" 2>/dev/null)
if [ -n "$PIDS" ]; then
    kill -9 $PIDS 2>/dev/null
    echo "  -> 残留进程已终止 (PID: $PIDS)"
else
    echo "  -> 无残留进程"
fi

echo "=========================================================="
echo "卸载完成，已无任何残留。"
echo "=========================================================="
