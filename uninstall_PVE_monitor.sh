#!/bin/bash

# ---------- 配置定义 (需与部署脚本一致) ----------
MONITOR_SCRIPT="/root/pve_host_monitor.sh"
LOG_FILE="/var/log/pve_host_monitor.log"
PVE_MARK="/root/pve_did_reboot_today"
DEPLOY_SCRIPT="/root/network_monitor_deploy_pve_v2.sh"

echo "=========================================================="
echo "      PVE 哨兵模式 (PVE Host Monitor) 彻底卸载工具"
echo "=========================================================="

# 1. 停止运行中的进程
echo "[1/4] 正在停止监控进程..."
# 使用 pkill 匹配脚本名称
if pkill -f "$MONITOR_SCRIPT"; then
    echo "  -> 已成功终止正在运行的监控进程。"
else
    echo "  -> 未发现运行中的监控进程。"
fi

# 2. 清理 Crontab 定时任务
echo "[2/4] 正在清理 Crontab 定时任务..."
# 备份当前的 crontab 到临时文件，过滤掉包含关键字的行，再写回
crontab -l 2>/dev/null > /tmp/cron_bak
if [ -s /tmp/cron_bak ]; then
    grep -v -E "pve_host_monitor.sh|pve_did_reboot_today" /tmp/cron_bak > /tmp/cron_new
    crontab /tmp/cron_new
    echo "  -> 已移除凌晨重置与开机自启任务。"
else
    echo "  -> 未发现相关 Crontab 任务。"
fi
rm -f /tmp/cron_bak /tmp/cron_new

# 3. 删除物理文件
echo "[3/4] 正在清理脚本、日志与标记文件..."
[ -f "$MONITOR_SCRIPT" ] && rm -v "$MONITOR_SCRIPT"
[ -f "$PVE_MARK" ] && rm -v "$PVE_MARK"
[ -f "$LOG_FILE" ] && rm -v "$LOG_FILE"
# 注意：这里选择保留部署脚本本身，如需删除可取消下面一行的注释
# [ -f "$DEPLOY_SCRIPT" ] && rm -v "$DEPLOY_SCRIPT"

# 4. 最终状态检查
echo "[4/4] 正在验证清理结果..."
STILL_RUNNING=$(ps aux | grep "$MONITOR_SCRIPT" | grep -v grep)
if [ -z "$STILL_RUNNING" ]; then
    echo "  -> 验证通过：无残留进程。"
else
    echo "  -> 警告：仍有进程在运行，请尝试手动执行 'kill -9'。"
fi

echo "=========================================================="
echo " 卸载完成！PVE 宿主机已恢复原始状态。"
echo "=========================================================="
