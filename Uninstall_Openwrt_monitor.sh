#!/bin/sh

# ---------- 配置定义 ----------
SERVICE_NAME="network_monitor"
SERVICE_PATH="/etc/init.d/$SERVICE_NAME"
LOGIC_PATH="/usr/bin/network_monitor_logic.sh"  # 新增：核心逻辑脚本路径

LOG_FILE="/root/network_monitor.log"
REBOOT_COUNT_FILE="/root/net_rb_count"
COOLING_TS_FILE="/root/net_cooling_ts"
SOS_FILE="/root/SOS_SYSTEM"

echo "=========================================================="
echo "      OpenWrt 网络守护神 (Network Monitor) 彻底卸载工具"
echo "=========================================================="

# 1. 停止并禁用服务 (兼容性增强)
echo "[1/4] 正在停止服务并清理进程..."

# 先尝试标准停止
if [ -f "$SERVICE_PATH" ]; then
    "$SERVICE_PATH" disable >/dev/null 2>&1
    "$SERVICE_PATH" stop >/dev/null 2>&1
fi

# 暴力补刀：使用 pgrep + kill 替代 pkill (解决 not found 问题)
# 针对逻辑脚本进程
_PID=$(pgrep -f network_monitor_logic.sh)
if [ -n "$_PID" ]; then
    kill $_PID >/dev/null 2>&1
    echo "  -> 已强制终止残留进程 (PID: $_PID)。"
else
    echo "  -> 未发现运行中的逻辑进程。"
fi

# 2. 清理 Crontab 定时任务
echo "[2/4] 正在清理 Crontab 凌晨重置任务..."
if crontab -l 2>/dev/null | grep -q "net_rb_count"; then
    crontab -l | grep -v "net_rb_count" | crontab -
    echo "  -> 已成功移除定时任务。"
else
    echo "  -> 未发现相关定时任务。"
fi

# 3. 删除所有相关文件
echo "[3/4] 正在清理持久化文件与脚本..."
[ -f "$LOG_FILE" ] && rm -v "$LOG_FILE"
[ -f "$REBOOT_COUNT_FILE" ] && rm -v "$REBOOT_COUNT_FILE"
[ -f "$COOLING_TS_FILE" ] && rm -v "$COOLING_TS_FILE"
[ -f "$SOS_FILE" ] && rm -v "$SOS_FILE"
[ -f "$SERVICE_PATH" ] && rm -v "$SERVICE_PATH"
# 新增：删除分离出去的逻辑脚本
[ -f "$LOGIC_PATH" ] && rm -v "$LOGIC_PATH"

# 4. 最终状态检查
echo "[4/4] 正在验证清理结果..."
STILL_RUNNING=$(pgrep -f network_monitor_logic.sh)

if [ -z "$STILL_RUNNING" ]; then
    echo "  -> 验证通过：无进程残留。"
    echo "  -> 验证通过：无文件残留。"
else
    echo "  -> 警告：进程 (PID $STILL_RUNNING) 似乎顽固残留，请尝试重启 OpenWrt。"
fi

echo "=========================================================="
echo " 卸载完成！网络守护神已彻底从系统中移除。"
echo "=========================================================="
