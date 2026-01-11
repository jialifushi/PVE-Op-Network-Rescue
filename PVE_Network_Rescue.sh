#!/bin/bash

# ---------- 配置区域 ----------
VM_ID="110"                       # 您的 OpenWrt 虚拟机 ID
OP_IP="192.168.10.1"               # OpenWrt 的内网 IP
TARGET_IP="www.baidu.com"       # 互联网检测目标
MONITOR_SCRIPT="/root/pve_host_monitor.sh"
LOG_FILE="/var/log/pve_host_monitor.log"
PVE_MARK="/root/pve_did_reboot_today"

echo "=========================================================="
echo "      PVE 宿主机守护神 (PVE Host Monitor) 部署工具"
echo "=========================================================="

# 1. 环境自检
echo "[1/4] 正在检测 SSH 免密登录环境..."
# 检查是否能免密登录，设置 5 秒超时
if ! ssh -o ConnectTimeout=5 -o BatchMode=yes root@$OP_IP "echo OK" >/dev/null 2>&1; then
    echo "  [错误] 无法免密登录 OpenWrt ($OP_IP)。"
    echo "  请先在 PVE 执行: ssh-copy-id root@$OP_IP"
    exit 1
fi
echo "  -> SSH 通讯正常。"

# 2. 生成核心守护脚本
echo "[2/4] 正在生成核心监控逻辑..."
cat << 'EOF' > "$MONITOR_SCRIPT"
#!/bin/bash

# 导入配置（由部署脚本填充）直接将变量通过 cat 写入，不再二次 sed
cat << EOF > "$MONITOR_SCRIPT"
#!/bin/bash
OP_IP="$OP_IP"
TARGET_IP="$TARGET_IP"
CHECK_INTERVAL=7200           # 2小时检测一次
RETRY_PING_OP_INTERVAL=40     # 等待 OP 恢复的频率
LOG_FILE="$LOG_FILE"
PVE_MARK="$PVE_MARK"

log_pve() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"
}

while true; do
    # 每天 0 点由 Crontab 删除标记
    if [ -f "$PVE_MARK" ]; then
        sleep 600 # 已救过，休眠 10 分钟后再次检查标记是否存在
        continue
    fi

    # 监测互联网 (低频)
    if ! ping -c 2 -W 5 "$TARGET_IP" > /dev/null 2>&1; then
        log_pve "【检测】互联网断开，开始检索 OpenWrt SOS 信号..."

        # 核心：带超时的 SSH 检查信号
        SOS_STATUS=$(ssh -o ConnectTimeout=10 -o BatchMode=yes root@$OP_IP "[ -f /root/SOS_SYSTEM ] && echo 'SOS'" 2>/dev/null)

        if [ "$SOS_STATUS" == "SOS" ]; then
            log_pve "【确认】捕获 SOS 信号！OpenWrt 自救已穷尽。准备介入重启 PVE。"

            # 冲突规避：等待 OpenWrt 稳定在线（防止在 OP 重启中途 PVE 也重启）
            while ! ping -c 1 -W 2 "$OP_IP" > /dev/null 2>&1; do
                log_pve "【等待】OpenWrt 响应超时（可能正在自愈重启中），40秒后重试..."
                sleep "$RETRY_PING_OP_INTERVAL"
            done

            log_pve "【同步】OpenWrt 已稳定，开始下达系统重启指令..."
            
            # --- 重启前的终极三部曲 ---
            # 1. 登录 OP 删除 SOS 信号文件
            ssh -o ConnectTimeout=10 root@$OP_IP "rm -f /root/SOS_SYSTEM"
            # 2. 标记 PVE 今日已处理
            touch "$PVE_MARK"
            # 3. 记录重启时刻
            log_pve "【终极动作】删除 SOS 成功。PVE 物理机将在 10 秒后强制重启！"
            
            sync
            sleep 10
            reboot
        else
            log_pve "【观察】未发现 SOS 信号。判定 OpenWrt 仍在尝试自愈或处于熔断期。"
        fi
    fi
    sleep "$CHECK_INTERVAL"
done
EOF

# 修正脚本中的变量值（确保与部署配置同步）
sed -i "s/OP_IP=.*/OP_IP=\"$OP_IP\"/" "$MONITOR_SCRIPT"
sed -i "s/TARGET_IP=.*/TARGET_IP=\"$TARGET_IP\"/" "$MONITOR_SCRIPT"
chmod +x "$MONITOR_SCRIPT"
echo "  -> 核心脚本已就绪。"

# 3. 配置定时任务
echo "[3/4] 正在配置系统计划任务 (Crontab)..."
# 确保凌晨清空标记
if ! crontab -l 2>/dev/null | grep -q "$PVE_MARK"; then
    (crontab -l 2>/dev/null; echo "0 0 * * * rm -f $PVE_MARK") | crontab -
fi
# 确保监控脚本在系统启动时自动运行
if ! crontab -l 2>/dev/null | grep -q "$MONITOR_SCRIPT"; then
    (crontab -l 2>/dev/null; echo "@reboot /bin/bash $MONITOR_SCRIPT &") | crontab -
fi
echo "  -> Crontab 任务配置完成。"

# 4. 立即启动
echo "[4/4] 正在初始化监控进程..."
pkill -f "$MONITOR_SCRIPT" # 杀掉旧进程（防止重复部署）
nohup /bin/bash "$MONITOR_SCRIPT" > /dev/null 2>&1 &

echo "=========================================================="
echo "部署成功！PVE 宿主机现已进入“哨兵”模式。"
echo "----------------------------------------------------------"
echo "【如何回顾过去一个月的系统情况？】"
echo " 由于我们配置了详细的学习日志，您可以执行以下操作进行历史诊断："
echo ""
echo " 1. 查看 PVE 重启记录："
echo "    grep \"终极动作\" $LOG_FILE"
echo ""
echo " 2. 统计过去一个月 PVE 介入的次数："
echo "    grep \"终极动作\" $LOG_FILE | cut -d' ' -f1 | cut -d'-' -f1,2 | uniq -c"
echo ""
echo " 3. 查看网络波动的历史频率（包含 OP 报错记录）："
echo "    tail -n 1000 $LOG_FILE"
echo "----------------------------------------------------------"
echo " PVE 日志路径: $LOG_FILE"
echo " OpenWrt 日志: ssh root@$OP_IP 'cat /root/network_monitor.log'"
echo "=========================================================="
echo " 4. 查看 OpenWrt 自愈历史："
echo "    ssh root@$OP_IP 'tail -n 100 /root/network_monitor.log'"
