#!/bin/bash
# ============================================================
# PVE 网络守卫脚本 - 自动检测断网并重启
# 功能：每隔一段时间 ping 检测目标，断网则重启
# 冷却时间：至少 4 小时，防止频繁重启
# ============================================================

# ─── 配置区 ──────────────────────────────────────────────────
TARGET_IP="www.baidu.com"           # 检测目标（百度）
CHECK_INTERVAL=300                   # 正常检测间隔：5 分钟
COOLDOWN_SECONDS=14400               # 最短冷却时间：4 小时 = 14400 秒
COOLDOWN_TS_FILE="/var/run/pve_watchdog_last_reboot.ts"  # 记录上次重启时刻
LOG_FILE="/var/log/pve_watchdog.log" # 日志路径（与 demo 不同）
PING_COUNT=3                         # 每次 ping 包数
PING_TIMEOUT=5                       # 每次 ping 超时秒数
CONFIRM_WAIT=30                      # 首次断网后，等待 N 秒二次确认
# ─────────────────────────────────────────────────────────────

# ─── 日志函数 ─────────────────────────────────────────────────
log_wd() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"
}
# ─────────────────────────────────────────────────────────────

# ─── 检查是否在冷却期 ────────────────────────────────────────
in_cooldown() {
    if [ ! -f "$COOLDOWN_TS_FILE" ]; then
        return 1  # 不在冷却期
    fi
    LAST_REBOOT=$(cat "$COOLDOWN_TS_FILE" 2>/dev/null)
    NOW=$(date +%s)
    ELAPSED=$(( NOW - LAST_REBOOT ))
    if [ "$ELAPSED" -lt "$COOLDOWN_SECONDS" ]; then
        REMAIN=$(( COOLDOWN_SECONDS - ELAPSED ))
        log_wd "【冷却】距上次重启仅 ${ELAPSED} 秒，剩余冷却时间 ${REMAIN} 秒，跳过本次重启。"
        return 0  # 在冷却期
    fi
    return 1  # 冷却已过
}
# ─────────────────────────────────────────────────────────────

# ─── 三层重启机制 ─────────────────────────────────────────────
do_reboot() {
    log_wd "==========================================="
    log_wd "【REBOOT】PVE 三层重启机制已触发"
    log_wd "==========================================="

    # 记录本次重启时刻（冷却计时开始）
    date +%s > "$COOLDOWN_TS_FILE"
    log_wd "【冷却】已写入重启时间戳，${COOLDOWN_SECONDS} 秒冷却期开始。"

    # 同步磁盘
    sync

    # ─── 第一层：systemd 双重强制重启 ────────────────────────
    log_wd "【L1】尝试 systemd 双重强制重启..."
    sleep 3
    /usr/bin/systemctl --force --force reboot
    log_wd "【L1】命令已发送，等待 15 秒观察是否生效..."
    sleep 15

    # ─── 第二层：再次确认 ─────────────────────────────────────
    log_wd "【L2】systemd 双重强制重启未生效，尝试普通 reboot..."
    /usr/bin/systemctl reboot
    sleep 10
    /usr/sbin/reboot
    log_wd "【L2】再次尝试后仍未重启，进入最终阶段..."
    sleep 10

    # ─── 第三层：内核级 SysRq 强制重启 ──────────────────────
    log_wd "【L3】触发内核级 SysRq 强制重启（立即执行）"
    echo 1 > /proc/sys/kernel/sysrq
    sync
    sleep 2
    echo b > /proc/sysrq-trigger

    # 如果还能执行到这里，说明系统严重异常
    sleep 30
    log_wd "【异常】SysRq 重启未执行，系统可能已严重异常！"
    log_wd "【回退】删除冷却时间戳，下次检测周期将再次尝试重启。"
    rm -f "$COOLDOWN_TS_FILE"
}
# ─────────────────────────────────────────────────────────────

# ─── 主循环 ──────────────────────────────────────────────────
log_wd "【启动】PVE 网络守卫启动，目标: $TARGET_IP，检测间隔: ${CHECK_INTERVAL}s，冷却: ${COOLDOWN_SECONDS}s"

while true; do

    # 一次 ping 检测
    if ping -c "$PING_COUNT" -W "$PING_TIMEOUT" "$TARGET_IP" > /dev/null 2>&1; then
        # 网络正常，静默等待
        sleep "$CHECK_INTERVAL"
        continue
    fi

    # ── 疑似断网，等待后二次确认（避免瞬断误判）──────────────
    log_wd "【检测】Ping $TARGET_IP 失败，等待 ${CONFIRM_WAIT}s 后二次确认..."
    sleep "$CONFIRM_WAIT"

    if ping -c "$PING_COUNT" -W "$PING_TIMEOUT" "$TARGET_IP" > /dev/null 2>&1; then
        log_wd "【恢复】二次确认：网络已恢复（可能是瞬断），无需操作。"
        sleep "$CHECK_INTERVAL"
        continue
    fi

    # ── 二次确认仍然断网 ───────────────────────────────────────
    log_wd "【确认】二次确认：网络确实断开！"

    # ── 检查冷却期 ─────────────────────────────────────────────
    if in_cooldown; then
        sleep "$CHECK_INTERVAL"
        continue
    fi

    # ── 触发重启 ───────────────────────────────────────────────
    log_wd "【决策】冷却期已过，决定执行重启！"
    do_reboot

    # 重启后脚本不应继续执行，但防御性等待
    sleep "$CHECK_INTERVAL"
done
# ─────────────────────────────────────────────────────────────
