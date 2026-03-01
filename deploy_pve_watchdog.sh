#!/bin/bash
# ============================================================
# PVE 网络守卫 - 一键部署脚本
# 运行方式：bash deploy_pve_watchdog.sh
# ============================================================

SCRIPT_DEST="/usr/local/bin/pve_watchdog.sh"
LOG_FILE="/var/log/pve_watchdog.log"
SERVICE_FILE="/etc/systemd/system/pve-watchdog.service"

echo "=========================================================="
echo "         PVE 网络守卫 - 一键部署"
echo "=========================================================="

# 1. 复制主脚本
echo "[1/4] 部署监控主脚本..."
cp "$(dirname "$0")/pve_watchdog.sh" "$SCRIPT_DEST"
chmod +x "$SCRIPT_DEST"
echo "  -> 脚本已写入 $SCRIPT_DEST"

# 2. 初始化日志文件
echo "[2/4] 初始化日志文件..."
touch "$LOG_FILE"
echo "  -> 日志路径: $LOG_FILE"

# 3. 创建 systemd 服务（开机自启）
echo "[3/4] 注册 systemd 开机自启服务..."
cat > "$SERVICE_FILE" << 'EOF'
[Unit]
Description=PVE Network Watchdog - Auto Reboot on Network Failure
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/bin/bash /usr/local/bin/pve_watchdog.sh
Restart=always
RestartSec=60
StandardOutput=null
StandardError=null

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable pve-watchdog.service
systemctl restart pve-watchdog.service
echo "  -> systemd 服务已启用并启动"

# 4. 验证状态
echo "[4/4] 验证运行状态..."
sleep 2
STATUS=$(systemctl is-active pve-watchdog.service)
echo "  -> 服务状态: $STATUS"

echo "=========================================================="
echo "部署完成！PVE 网络守卫已运行。tail -f /var/log/pve_watchdog.log"
echo "----------------------------------------------------------"
echo "【常用命令】"
echo " 查看实时日志：tail -f $LOG_FILE"
echo " 查看服务状态：systemctl status pve-watchdog"
echo " 查看重启记录：grep 'REBOOT\|终极\|触发' $LOG_FILE"
echo " 查看冷却状态：cat /var/run/pve_watchdog_last_reboot.ts"
echo " 手动停止服务：systemctl stop pve-watchdog"
echo " 查看断网历史：grep '确认' $LOG_FILE"
echo "=========================================================="
