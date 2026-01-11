#!/bin/bash

# ---------- 配置定义 ----------
MONITOR_SCRIPT="/root/pve_host_monitor.sh"
LOG_FILE="/var/log/pve_host_monitor.log"
PVE_MARK="/root/pve_did_reboot_today"
# 部署脚本名称，用于提示（不强制删除）
DEPLOY_SCRIPT="/root/network_monitor_deploy_pve_v2.sh"

echo "=========================================================="
echo "      PVE 哨兵模式 (PVE Host Monitor) 彻底卸载工具"
echo "=========================================================="

# 1. 停止运行中的进程 (使用更通用的 pgrep 方案)
echo "[1/4] 正在停止监控进程..."
_PID=$(pgrep -f "$MONITOR_SCRIPT")

if [ -n "$_PID" ]; then
    kill $_PID
    echo "  -> 已发送终止信号给进程 (PID: $_PID)。"
    # 等待一秒确保进程退出
    sleep 1
    # 二次确认，如果还在就强制杀
    if pgrep -f "$MONITOR_SCRIPT" >/dev/null; then
        kill -9 $_PID 2>/dev/null
        echo "  -> [警告] 进程顽固，已执行强制击杀 (kill -9)。"
    fi
else
    echo "  -> 未发现运行中的监控进程。"
fi

# 2. 清理 Crontab 定时任务
echo "[2/4] 正在清理 Crontab 定时任务..."
# 备份当前的 crontab
crontab -l 2>/dev/null > /tmp/cron_bak

if [ -s /tmp/cron_bak ]; then
    # 检查是否存在相关任务
    if grep -q -E "pve_host_monitor.sh|pve_did_reboot_today" /tmp/cron_bak; then
        grep -v -E "pve_host_monitor.sh|pve_did_reboot_today" /tmp/cron_bak > /tmp/cron_new
        crontab /tmp/cron_new
        echo "  -> 已移除凌晨重置与开机自启任务。"
    else
        echo "  -> Crontab 中未发现相关任务，无需清理。"
    fi
else
    echo "  -> Crontab 为空，无需清理。"
fi
rm -f /tmp/cron_bak /tmp/cron_new

# 3. 删除物理文件
echo "[3/4] 正在清理脚本、日志与标记文件..."
[ -f "$MONITOR_SCRIPT" ] && rm -v "$MONITOR_SCRIPT"
[ -f "$PVE_MARK" ] && rm -v "$PVE_MARK"
[ -f "$LOG_FILE" ] && rm -v "$LOG_FILE"

# 4. 最终状态检查
echo "[4/4] 正在验证清理结果..."
STILL_RUNNING=$(pgrep -f "$MONITOR_SCRIPT")

if [ -z "$STILL_RUNNING" ]; then
    echo "  -> 验证通过：无残留进程。"
    # 检查文件是否真的没了
    if [ ! -f "$MONITOR_SCRIPT" ]; then
        echo "  -> 验证通过：脚本文件已删除。"
    fi
else
    echo "  -> [严重警告] 仍有进程 (PID $STILL_RUNNING) 在运行，请手动检查！"
fi

echo "=========================================================="
echo " 卸载完成！PVE 宿主机已恢复原始状态。"
echo "=========================================================="
