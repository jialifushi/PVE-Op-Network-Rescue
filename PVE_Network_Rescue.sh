#!/bin/bash

# ---------- 配置区域 ----------
VM_ID="110"                        # 您的 OpenWrt 虚拟机 ID
OP_IP="192.168.10.1"               # OpenWrt 的内网 IP
TARGET_IP="www.baidu.com"        # 互联网检测目标
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

# 注意：这里修正了原代码中 cat 嵌套写入的逻辑冲突，直接生成最终脚本内容
cat << EOF > "$MONITOR_SCRIPT"
#!/bin/bash
OP_IP="$OP_IP"
TARGET_IP="$TARGET_IP"
CHECK_INTERVAL=7200           # 2小时检测一次
RETRY_PING_OP_INTERVAL=40     # 等待 OP 恢复的频率
LOG_FILE="$LOG_FILE"
PVE_MARK="$PVE_MARK"

# ---------------- 新增：核心超时配置参数 ----------------
VM_SHUTDOWN_TIMEOUT=60        # 虚拟机第一次关机等待超时 (秒)
VM_SHUTDOWN_RETRY_TIMEOUT=60  # 虚拟机第二次关机等待超时 (秒)
L1_WAIT=120                   # L1 层重启观察期 (秒)
L2_WAIT=60                    # L2 层重启观察期 (秒)
L3_WAIT=30                    # L3 层重启观察期 (秒)
L4_WAIT=60                    # L4 层内核重启观察期 (秒)

log_pve() {
    echo "\$(date '+%Y-%m-%d %H:%M:%S') \$1" >> "\$LOG_FILE"
}

# ---------------- 新增函数：等待虚拟机关闭 ----------------
wait_vm_shutdown() {
    local vmid=\$1
    local timeout=\$2
    local count=0
    while [ \$count -lt \$timeout ]; do
        if ! qm status "\$vmid" 2>/dev/null | grep -q "status: running"; then
            return 0 # 已关机返回成功
        fi
        sleep 1
        count=\$((count + 1))
    done
    return 1 # 超时返回失败
}

# ---------------- 新增函数：串行关闭所有虚拟机 ----------------
shutdown_all_vms() {
    log_pve "==========================================="
    log_pve "【VM】开始执行所有运行中虚拟机的优雅关机流程"
    log_pve "==========================================="
    local RUNNING_VMS=\$(qm list 2>/dev/null | awk '\$3 == "running" {print \$1}')
    local TOTAL=\$(echo "\$RUNNING_VMS" | grep -c '[^[:space:]]' || true)
    
    if [ -z "\$RUNNING_VMS" ] || [ "\$TOTAL" -eq 0 ]; then
        log_pve "【VM】当前没有运行中的虚拟机，跳过关机流程。"
        return
    fi

    local INDEX=0
    for VMID in \$RUNNING_VMS; do
        INDEX=\$(( INDEX + 1 ))
        local VMNAME=\$(qm config "\$VMID" 2>/dev/null | grep '^name:' | awk '{print \$2}')
        [ -z "\$VMNAME" ] && VMNAME="未知"
        
        log_pve "【VM \$INDEX/\$TOTAL】VMID=\$VMID 名称=\$VMNAME - 发送第一次优雅关机指令..."
        qm shutdown "\$VMID" >/dev/null 2>&1
        log_pve "【VM \$INDEX/\$TOTAL】VMID=\$VMID - 等待关机，超时时间 \${VM_SHUTDOWN_TIMEOUT}s..."
        
        if wait_vm_shutdown "\$VMID" "\$VM_SHUTDOWN_TIMEOUT"; then
            log_pve "【VM \$INDEX/\$TOTAL】VMID=\$VMID 名称=\$VMNAME ✔ 第一次关机成功。"
            continue
        fi
        
        # 第一次超时，发起第二次
        log_pve "【VM \$INDEX/\$TOTAL】VMID=\$VMID 名称=\$VMNAME ✘ 第一次关机超时（\${VM_SHUTDOWN_TIMEOUT}s），发起第二次尝试..."
        qm shutdown "\$VMID" >/dev/null 2>&1
        log_pve "【VM \$INDEX/\$TOTAL】VMID=\$VMID - 等待第二次关机，超时时间 \${VM_SHUTDOWN_RETRY_TIMEOUT}s..."
        
        if wait_vm_shutdown "\$VMID" "\$VM_SHUTDOWN_RETRY_TIMEOUT"; then
            log_pve "【VM \$INDEX/\$TOTAL】VMID=\$VMID 名称=\$VMNAME ✔ 第二次关机成功。"
            continue
        fi
        
        # 两次均失败，兜底强制关闭
        log_pve "【VM \$INDEX/\$TOTAL】VMID=\$VMID 名称=\$VMNAME ✘ 两次关机均超时，跳过优雅关闭。"
        log_pve "【VM \$INDEX/\$TOTAL】VMID=\$VMID ⚠ 警告：正执行 qm stop 强制断电，可能存在数据风险！"
        qm stop "\$VMID" >/dev/null 2>&1
    done
    log_pve "-------------------------------------------"
    log_pve "【VM】所有虚拟机处理完毕（共 \${TOTAL} 台），准备执行宿主机重启。"
    log_pve "-------------------------------------------"
}

# ---------------- 新增函数：四层递进式重启机制 ----------------
do_reboot() {
    log_pve "==========================================="
    log_pve "【REBOOT】PVE 四层重启机制已触发"
    log_pve "==========================================="
    
    # 1. 串行优雅关闭虚拟机
    shutdown_all_vms
    
    # 2. 磁盘同步
    log_pve "【REBOOT】执行系统级磁盘同步 sync..."
    sync

    # ─── L1：优雅重启 ────────────────────────────────────────
    log_pve "-------------------------------------------"
    log_pve "【L1】systemctl reboot - 优雅重启，等待剩余系统服务关闭..."
    log_pve "-------------------------------------------"
    /usr/bin/systemctl reboot
    log_pve "【L1】指令已发送，等待 \${L1_WAIT}s 观察是否生效..."
    sleep "\$L1_WAIT"

    # ─── L2：跳过服务流程 ────────────────────────────────────
    log_pve "-------------------------------------------"
    log_pve "【L2】L1 未生效，尝试 systemctl reboot --force（跳过服务停止流程）..."
    log_pve "-------------------------------------------"
    /usr/bin/systemctl reboot --force
    log_pve "【L2】指令已发送，等待 \${L2_WAIT}s 观察是否生效..."
    sleep "\$L2_WAIT"

    # ─── L3：直接调用内核 reboot() ───────────────────────────
    log_pve "-------------------------------------------"
    log_pve "【L3】L2 未生效，尝试 systemctl reboot --force --force（直接内核 reboot）..."
    log_pve "-------------------------------------------"
    sync
    /usr/bin/systemctl reboot --force --force
    log_pve "【L3】指令已发送，等待 \${L3_WAIT}s 观察是否生效..."
    sleep "\$L3_WAIT"

    # ─── L4：内核 SysRq 终极重启 ─────────────────────────────
    log_pve "-------------------------------------------"
    log_pve "【L4】L3 未生效，触发内核级 SysRq 强制重启（最终手段）..."
    log_pve "-------------------------------------------"
    echo 1 > /proc/sys/kernel/sysrq
    
    log_pve "【L4】触发内核态 sync (强制刷入脏数据)..."
    echo s > /proc/sysrq-trigger
    sleep 2
    
    log_pve "【L4】触发内核态 umount (将文件系统重挂载为只读)..."
    echo u > /proc/sysrq-trigger
    sleep 1
    
    log_pve "【L4】SysRq 写入 b，系统应立即物理重启..."
    sync
    echo b > /proc/sysrq-trigger

    # ─── 全部失效兜底 ─────────────────────────────────────────
    sleep "\$L4_WAIT"
    log_pve "【严重异常】四层重启机制全部失效！系统底层可能已彻底锁死。"
    log_pve "【回退】正在撕毁免死金牌，以便在下个检测周期重试。"
    rm -f "\$PVE_MARK"
}

# [必须加入的位置]：脚本加载后的第一件事，就是打个招呼
log_pve "==========================================="
log_pve "【系统启动】PVE 哨兵脚本已加载并进入后台模式"
log_pve "==========================================="

while true; do
    # 每天 0 点由 Crontab 删除标记
    if [ -f "\$PVE_MARK" ]; then
        sleep 600 # 已救过，休眠 10 分钟后再次检查标记是否存在
        continue
    fi

    # 监测互联网 (低频)
    if ! ping -c 2 -W 5 "\$TARGET_IP" > /dev/null 2>&1; then
        log_pve "【检测】互联网断开，开始检索 OpenWrt SOS 信号..."

        # 核心：带超时的 SSH 检查信号
        SOS_STATUS=\$(ssh -o ConnectTimeout=10 -o BatchMode=yes root@\$OP_IP "[ -f /root/SOS_SYSTEM ] && echo 'SOS'" 2>/dev/null)

        if [ "\$SOS_STATUS" == "SOS" ]; then
            log_pve "【确认】捕获 SOS 信号！OpenWrt 自救已穷尽。准备介入重启 PVE。"

            # 冲突规避：等待 OpenWrt 稳定在线（防止在 OP 重启中途 PVE 也重启）
            while ! ping -c 1 -W 2 "\$OP_IP" > /dev/null 2>&1; do
                log_pve "【等待】OpenWrt 响应超时（可能正在自愈重启中），40秒后重试..."
                sleep "\$RETRY_PING_OP_INTERVAL"
            done

            log_pve "【同步】OpenWrt 已稳定，开始下达系统重启指令..."
            
            # --- 重启前的终极三部曲 ---
            # 1. 登录 OP 删除 SOS 信号文件
            # 既删除 SOS 信号，又重置 OpenWrt 的重启计数，给它重生的机会
            ssh -o ConnectTimeout=10 root@\$OP_IP "rm -f /root/SOS_SYSTEM && echo 0 > /root/net_rb_count && rm -f /root/net_cooling_ts"
            
            # 2. 标记 PVE 今日已处理 (免死金牌)
            touch "\$PVE_MARK"
            
            # 3. 记录重启时刻
            log_pve "【终极动作】删除 SOS 成功。准备执行串行关机与四层系统重启机制..."
            
            sync
            sleep 10

            # --- [合入修改：调用串行关机与四层重启机制] ---
            do_reboot
            # ----------------------------------
            
        else
            log_pve "【观察】未发现 SOS 信号。判定 OpenWrt 仍在尝试自愈或处于熔断期。"
        fi
    fi
    sleep "\$CHECK_INTERVAL"
done
EOF

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
