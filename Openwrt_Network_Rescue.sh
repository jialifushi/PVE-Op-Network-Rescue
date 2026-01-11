#!/bin/sh

# 强制检查是否在 OpenWrt 环境
if [ ! -f "/etc/openwrt_release" ] && [ ! -f "/etc/rc.common" ]; then
    echo "=========================================================="
    echo " 错误：检测到当前系统不是 OpenWrt！"
    echo "=========================================================="
    exit 1
fi

# 定义核心路径
SERVICE_PATH="/etc/init.d/network_monitor"
LOGIC_PATH="/usr/bin/network_monitor_logic.sh"

# 定义文件路径
LOG_FILE="/root/network_monitor.log"
REBOOT_COUNT_FILE="/root/net_rb_count"
COOLING_TS_FILE="/root/net_cooling_ts"
SOS_FILE="/root/SOS_SYSTEM"

echo "=========================================================="
echo "      OpenWrt 网络守护神 - 终极审计版 (v3.0)"
echo "      包含完整逻辑 + 命令执行结果深度审计"
echo "=========================================================="

# ---------- 阶段 1: 环境清理与初始化 ----------
echo "[1/4] 正在清理旧环境..."

# 停止服务
[ -f "$SERVICE_PATH" ] && "$SERVICE_PATH" stop >/dev/null 2>&1
# 杀掉残留进程
_PID=$(pgrep -f network_monitor_logic.sh)
if [ -n "$_PID" ]; then
    kill $_PID >/dev/null 2>&1
fi

# 初始化计数文件
[ ! -f "$REBOOT_COUNT_FILE" ] && echo 0 > "$REBOOT_COUNT_FILE"

# ---------- 阶段 2: 写入核心逻辑 (含深度审计) ----------
echo "[2/4] 写入深度审计逻辑脚本: $LOGIC_PATH"

cat << 'EOF' > "$LOGIC_PATH"
#!/bin/sh

# ---------- 配置区域 ----------
CHECK_IP="www.baidu.com"
CHECK_INTERVAL=60
SAFE_UPTIME=600

# 阈值
L1_THRESHOLD=2
L2_THRESHOLD=5
L3_THRESHOLD=10
L4_SOS_THRESHOLD=10

# 文件路径
LOG_FILE="/root/network_monitor.log"
REBOOT_COUNT_FILE="/root/net_rb_count"
COOLING_TS_FILE="/root/net_cooling_ts"
SOS_FILE="/root/SOS_SYSTEM"
LOG_MAX_LINE=2000

# 内部状态
retry_count=0

# --- 日志工具 ---
log_msg() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local msg="$1"
    
    # 日志轮转
    if [ -f "$LOG_FILE" ] && [ $(wc -l < "$LOG_FILE") -gt "$LOG_MAX_LINE" ]; then
        sed -i '1,300d' "$LOG_FILE"
        echo "[$timestamp] [SYSTEM] 日志触发回滚清理。" >> "$LOG_FILE"
    fi
    echo "[$timestamp] $msg" >> "$LOG_FILE"
    sync
}

get_rb_count() {
    [ -f "$REBOOT_COUNT_FILE" ] && cat "$REBOOT_COUNT_FILE" || echo 0
}

# --- 核心修复逻辑 (带审计) ---
run_fix_logic() {
    # 0. SOS 状态检查
    if [ -f "$SOS_FILE" ]; then
        if ping -c 1 -W 2 "$CHECK_IP" > /dev/null 2>&1; then
            rm -f "$SOS_FILE"
            log_msg "【SOS 撤回】检测到网络手动恢复，解除 SOS 状态。"
        else
            # 处于 SOS 状态且网络未通，静默跳过
            return 0
        fi
    fi

    # 1. 熔断检查
    if [ -f "$COOLING_TS_FILE" ]; then
        until_ts=$(cat "$COOLING_TS_FILE")
        now_ts=$(date +%s)
        if [ "$now_ts" -lt "$until_ts" ]; then
            # 冷却中，静默
            return 0
        fi
        rm -f "$COOLING_TS_FILE"
        log_msg "【熔断解除】冷静期结束，恢复正常监控。"
    fi

    # 2. 网络检测
    if ping -c 2 -W 5 "$CHECK_IP" > /dev/null 2>&1; then
        if [ "$retry_count" -gt 0 ]; then
            log_msg "【状态恢复】网络检测正常 (PONG)！重置故障计数。"
            retry_count=0
            echo 0 > "$REBOOT_COUNT_FILE"
        fi
    else
        # 网络断开
        retry_count=$((retry_count + 1))
        log_msg "【报警】网络断开 (第 $retry_count 次失败)。"

        # 3. 阶梯修复逻辑 (含 Exit Code 审计)
        
        # --- L1: WAN 重拨 ---
        if [ "$retry_count" -eq "$L1_THRESHOLD" ]; then
            log_msg "【L1-动作】正在执行 ifdown wan ..."
            ifdown wan
            if [ $? -eq 0 ]; then
                log_msg "   -> [成功] WAN 接口停止指令已送达。"
            else
                log_msg "   -> [错误] ifdown 执行失败。"
            fi
            
            sleep 5
            
            log_msg "【L1-动作】正在执行 ifup wan ..."
            ifup wan
            if [ $? -eq 0 ]; then
                log_msg "   -> [成功] WAN 接口启动指令已送达，等待拨号..."
            else
                log_msg "   -> [错误] ifup 执行失败。"
            fi

        # --- L2: 网络栈重启 ---
        elif [ "$retry_count" -eq "$L2_THRESHOLD" ]; then
            log_msg "【L2-动作】正在执行 /etc/init.d/network restart ..."
            /etc/init.d/network restart > /dev/null 2>&1
            if [ $? -eq 0 ]; then
                log_msg "   -> [成功] 网络栈重启指令执行完毕。"
            else
                log_msg "   -> [错误] 网络栈重启指令返回异常。"
            fi

        # --- L3: 系统重启 ---
        elif [ "$retry_count" -ge "$L3_THRESHOLD" ]; then
            uptime_sec=$(cut -d. -f1 /proc/uptime)
            
            # 安全锁
            if [ "$uptime_sec" -lt "$SAFE_UPTIME" ]; then
                log_msg "【安全锁】系统启动不足 10 分钟，跳过 L3 重启。"
            else
                rb_count=$(get_rb_count)
                rb_count=$((rb_count + 1))
                echo "$rb_count" > "$REBOOT_COUNT_FILE"

                # L4: SOS 判定
                if [ "$rb_count" -ge "$L4_SOS_THRESHOLD" ]; then
                    log_msg "【SOS】今日自愈已达 $rb_count 次上限。生成 SOS 信号，停止自救。"
                    touch "$SOS_FILE"
                    sync
                else
                    # 阶梯冷却计算
                    wait_h=$(( rb_count > 6 ? (rb_count - 6) : 0 ))
                    [ "$wait_h" -gt 3 ] && wait_h=3
                    
                    if [ "$wait_h" -gt 0 ]; then
                        echo $(($(date +%s) + wait_h * 3600)) > "$COOLING_TS_FILE"
                        log_msg "【L3-动作】执行物理重启 (#$rb_count)，重启后冷却 $wait_h 小时。"
                    else
                        log_msg "【L3-动作】执行物理重启 (#$rb_count)，暂不开启熔断。"
                    fi
                    
                    sleep 3
                    reboot
                fi
            fi
        fi
    fi
}

# --- 监控主循环 ---
log_msg "[SYSTEM] 监控进程启动 (审计模式 v3.0)。"

while true; do
    run_fix_logic
    sleep "$CHECK_INTERVAL"
done
EOF

chmod +x "$LOGIC_PATH"

# ---------- 阶段 3: 配置 Init.d 服务 ----------
echo "[3/4] 配置系统服务: $SERVICE_PATH"

cat << 'EOF' > "$SERVICE_PATH"
#!/bin/sh /etc/rc.common

USE_PROCD=1
START=99

start_service() {
    procd_open_instance
    # 明确调用逻辑脚本
    procd_set_param command /bin/sh /usr/bin/network_monitor_logic.sh
    procd_set_param respawn
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}

stop_service() {
    # 兼容性停止
    _PID=$(pgrep -f network_monitor_logic.sh)
    [ -n "$_PID" ] && kill $_PID
}
EOF

chmod +x "$SERVICE_PATH"
"$SERVICE_PATH" enable

# 配置 Crontab
if ! crontab -l 2>/dev/null | grep -q "net_rb_count"; then
    (crontab -l 2>/dev/null; echo "0 0 * * * echo 0 > /root/net_rb_count && rm -f /root/net_cooling_ts && rm -f /root/SOS_SYSTEM") | crontab -
    echo "  -> Crontab 任务已添加。"
fi

# ---------- 阶段 4: 启动与验证 ----------
echo "[4/4] 启动守护进程..."
"$SERVICE_PATH" restart
sleep 2

echo "----------------------------------------------------------"
# 最终检查
_FINAL_PID=$(pgrep -f network_monitor_logic.sh)

if [ -n "$_FINAL_PID" ]; then
    echo "部署状态: [ 成功运行中 ]"
    echo "进程 PID: $_FINAL_PID"
    echo "----------------------------------------------------------"
    echo "现在日志将显示详细的 [成功/错误] 审计信息。"
    echo "查看命令: tail -f $LOG_FILE"
else
    echo "部署状态: [ 启动失败 ]"
    echo "请检查 logread"
fi
echo "----------------------------------------------------------"
