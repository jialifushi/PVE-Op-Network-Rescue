#!/bin/bash
# ============================================================
# PVE 网络守卫脚本 v2.0
# 功能：检测断网后，串行优雅关闭所有虚拟机，再执行四层重启
# ============================================================

# ─── 配置区（按需修改） ──────────────────────────────────────
TARGET_IP="www.baidu.com"        # 检测目标
CHECK_INTERVAL=300               # 正常检测间隔（秒）：5 分钟
COOLDOWN_SECONDS=14400           # 重启冷却时间（秒）：4 小时
CONFIRM_WAIT=30                  # 首次断网后二次确认等待（秒）
PING_COUNT=3                     # 每次 ping 包数
PING_TIMEOUT=5                   # ping 超时（秒）

VM_SHUTDOWN_TIMEOUT=60           # 每台虚拟机单次关机等待时间（秒）
VM_SHUTDOWN_RETRY_TIMEOUT=60     # 第二次关机等待时间（秒）
VM_SHUTDOWN_CHECK_INTERVAL=5     # 检查虚拟机是否关闭的轮询间隔（秒）

L1_WAIT=20                       # L1 systemctl reboot 等待观察时间（秒）
L2_WAIT=15                       # L2 systemctl reboot --force 等待时间（秒）
L3_WAIT=15                       # L3 systemctl reboot --force --force 等待时间（秒）
L4_WAIT=30                       # L4 SysRq 等待时间（秒）

LOG_FILE="/var/log/pve_watchdog.log"                     # 日志路径
COOLDOWN_TS_FILE="/var/run/pve_watchdog_last_reboot.ts"  # 冷却时间戳
# ─────────────────────────────────────────────────────────────


# ─── 日志函数 ─────────────────────────────────────────────────
log_wd() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"
}
# ─────────────────────────────────────────────────────────────


# ─── 冷却期检查 ───────────────────────────────────────────────
in_cooldown() {
    if [ ! -f "$COOLDOWN_TS_FILE" ]; then
        return 1
    fi
    LAST_REBOOT=$(cat "$COOLDOWN_TS_FILE" 2>/dev/null)
    NOW=$(date +%s)
    ELAPSED=$(( NOW - LAST_REBOOT ))
    if [ "$ELAPSED" -lt "$COOLDOWN_SECONDS" ]; then
        REMAIN=$(( COOLDOWN_SECONDS - ELAPSED ))
        REMAIN_MIN=$(( REMAIN / 60 ))
        log_wd "【冷却】距上次重启仅 ${ELAPSED}s，冷却剩余 ${REMAIN}s（约 ${REMAIN_MIN} 分钟），跳过。"
        return 0
    fi
    return 1
}
# ─────────────────────────────────────────────────────────────


# ─── 等待单台虚拟机关机（带超时轮询） ────────────────────────
# 参数: $1=VMID  $2=超时秒数
# 返回: 0=已关机  1=超时未关机
wait_vm_shutdown() {
    local VMID="$1"
    local TIMEOUT="$2"
    local ELAPSED=0

    while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
        STATUS=$(qm status "$VMID" 2>/dev/null | awk '{print $2}')
        if [ "$STATUS" == "stopped" ]; then
            return 0
        fi
        sleep "$VM_SHUTDOWN_CHECK_INTERVAL"
        ELAPSED=$(( ELAPSED + VM_SHUTDOWN_CHECK_INTERVAL ))
    done
    return 1
}
# ─────────────────────────────────────────────────────────────


# ─── 串行优雅关闭所有虚拟机 ──────────────────────────────────
shutdown_all_vms() {
    log_wd "-------------------------------------------"
    log_wd "【VM】开始串行优雅关闭所有虚拟机..."
    log_wd "-------------------------------------------"

    # 获取所有运行中的虚拟机 ID
    RUNNING_VMS=$(qm list 2>/dev/null | awk 'NR>1 && $3=="running" {print $1}')

    if [ -z "$RUNNING_VMS" ]; then
        log_wd "【VM】当前无运行中的虚拟机，跳过关机流程。"
        return
    fi

    TOTAL=$(echo "$RUNNING_VMS" | wc -l)
    log_wd "【VM】检测到 ${TOTAL} 台运行中的虚拟机，开始逐台处理..."
    log_wd "【VM】虚拟机列表: $(echo $RUNNING_VMS | tr '\n' ' ')"

    INDEX=0
    for VMID in $RUNNING_VMS; do
        INDEX=$(( INDEX + 1 ))
        VMNAME=$(qm config "$VMID" 2>/dev/null | grep '^name:' | awk '{print $2}')
        [ -z "$VMNAME" ] && VMNAME="未知"

        log_wd "【VM $INDEX/$TOTAL】VMID=$VMID 名称=$VMNAME - 发送第一次优雅关机指令..."
        qm shutdown "$VMID" 2>/dev/null
        log_wd "【VM $INDEX/$TOTAL】VMID=$VMID - 等待关机，超时时间 ${VM_SHUTDOWN_TIMEOUT}s..."

        if wait_vm_shutdown "$VMID" "$VM_SHUTDOWN_TIMEOUT"; then
            log_wd "【VM $INDEX/$TOTAL】VMID=$VMID 名称=$VMNAME ✔ 第一次关机成功。"
            continue
        fi

        # 第一次超时，发起第二次
        log_wd "【VM $INDEX/$TOTAL】VMID=$VMID 名称=$VMNAME ✘ 第一次关机超时（${VM_SHUTDOWN_TIMEOUT}s），发起第二次尝试..."
        qm shutdown "$VMID" 2>/dev/null
        log_wd "【VM $INDEX/$TOTAL】VMID=$VMID - 等待第二次关机，超时时间 ${VM_SHUTDOWN_RETRY_TIMEOUT}s..."

        if wait_vm_shutdown "$VMID" "$VM_SHUTDOWN_RETRY_TIMEOUT"; then
            log_wd "【VM $INDEX/$TOTAL】VMID=$VMID 名称=$VMNAME ✔ 第二次关机成功。"
            continue
        fi

        # 两次均失败，跳过
        log_wd "【VM $INDEX/$TOTAL】VMID=$VMID 名称=$VMNAME ✘ 两次关机均超时，跳过优雅关闭。"
        log_wd "【VM $INDEX/$TOTAL】VMID=$VMID ⚠ 警告：该虚拟机将在宿主机重启时被强制终止，可能存在数据风险！"
    done

    log_wd "-------------------------------------------"
    log_wd "【VM】所有虚拟机处理完毕（共 ${TOTAL} 台），准备执行宿主机重启。"
    log_wd "-------------------------------------------"
}
# ─────────────────────────────────────────────────────────────


# ─── 四层重启机制 ─────────────────────────────────────────────
do_reboot() {
    log_wd "==========================================="
    log_wd "【REBOOT】PVE 四层重启机制已触发"
    log_wd "==========================================="

    # 写入冷却时间戳
    date +%s > "$COOLDOWN_TS_FILE"
    log_wd "【冷却】重启时间戳已写入，${COOLDOWN_SECONDS}s 冷却期开始。"

    # 串行优雅关闭虚拟机
    shutdown_all_vms

    # 磁盘同步
    log_wd "【REBOOT】执行磁盘同步 sync..."
    sync

    # ─── L1：优雅重启 ────────────────────────────────────────
    log_wd "-------------------------------------------"
    log_wd "【L1】systemctl reboot - 优雅重启，等待剩余系统服务关闭..."
    log_wd "-------------------------------------------"
    /usr/bin/systemctl reboot
    log_wd "【L1】指令已发送，等待 ${L1_WAIT}s 观察是否生效..."
    sleep "$L1_WAIT"

    # ─── L2：跳过服务流程 ────────────────────────────────────
    log_wd "-------------------------------------------"
    log_wd "【L2】L1 未生效，尝试 systemctl reboot --force（跳过服务停止流程）..."
    log_wd "-------------------------------------------"
    /usr/bin/systemctl reboot --force
    log_wd "【L2】指令已发送，等待 ${L2_WAIT}s 观察是否生效..."
    sleep "$L2_WAIT"

    # ─── L3：直接调用内核 reboot() ───────────────────────────
    log_wd "-------------------------------------------"
    log_wd "【L3】L2 未生效，尝试 systemctl reboot --force --force（直接内核 reboot）..."
    log_wd "-------------------------------------------"
    sync
    /usr/bin/systemctl reboot --force --force
    log_wd "【L3】指令已发送，等待 ${L3_WAIT}s 观察是否生效..."
    sleep "$L3_WAIT"

    # ─── L4：内核 SysRq 终极重启 ─────────────────────────────
    log_wd "-------------------------------------------"
    log_wd "【L4】L3 未生效，触发内核级 SysRq 强制重启（最终手段）..."
    log_wd "-------------------------------------------"
    echo 1 > /proc/sys/kernel/sysrq
    sync
    sleep 2
    log_wd "【L4】SysRq 写入 /proc/sysrq-trigger，系统应立即重启..."
    echo b > /proc/sysrq-trigger

    # ─── 全部失效兜底 ─────────────────────────────────────────
    sleep "$L4_WAIT"
    log_wd "【严重异常】四层重启机制全部失效！系统可能已严重异常。"
    log_wd "【回退】删除冷却时间戳，下次检测周期将重新触发重启流程。"
    rm -f "$COOLDOWN_TS_FILE"
}
# ─────────────────────────────────────────────────────────────


# ─── 主循环 ──────────────────────────────────────────────────
log_wd "==========================================="
log_wd "【启动】PVE 网络守卫 v2.0 已启动"
log_wd "【配置】检测目标     : $TARGET_IP"
log_wd "【配置】检测间隔     : ${CHECK_INTERVAL}s"
log_wd "【配置】冷却时间     : ${COOLDOWN_SECONDS}s（$(( COOLDOWN_SECONDS / 3600 )) 小时）"
log_wd "【配置】二次确认等待 : ${CONFIRM_WAIT}s"
log_wd "【配置】VM单次关机超时: ${VM_SHUTDOWN_TIMEOUT}s | 重试超时: ${VM_SHUTDOWN_RETRY_TIMEOUT}s"
log_wd "【配置】日志路径     : $LOG_FILE"
log_wd "==========================================="

while true; do

    # 正常 ping 检测，通过则静默等待
    if ping -c "$PING_COUNT" -W "$PING_TIMEOUT" "$TARGET_IP" > /dev/null 2>&1; then
        sleep "$CHECK_INTERVAL"
        continue
    fi

    # ── 疑似断网，等待二次确认，防止瞬断误判 ─────────────────
    log_wd "【检测】Ping $TARGET_IP 失败（${PING_COUNT} 包全丢），等待 ${CONFIRM_WAIT}s 后二次确认..."
    sleep "$CONFIRM_WAIT"

    if ping -c "$PING_COUNT" -W "$PING_TIMEOUT" "$TARGET_IP" > /dev/null 2>&1; then
        log_wd "【恢复】二次确认：网络已恢复（判定为瞬断），本次不触发重启。"
        sleep "$CHECK_INTERVAL"
        continue
    fi

    # ── 确认断网 ──────────────────────────────────────────────
    log_wd "【确认】二次确认：网络持续断开，目标 $TARGET_IP 不可达！"

    # ── 冷却期检查 ────────────────────────────────────────────
    if in_cooldown; then
        sleep "$CHECK_INTERVAL"
        continue
    fi

    # ── 触发完整流程 ──────────────────────────────────────────
    log_wd "【决策】冷却期已过，正式触发虚拟机关机 + 宿主机四层重启流程！"
    do_reboot

    sleep "$CHECK_INTERVAL"
done
# ─────────────────────────────────────────────────────────────
