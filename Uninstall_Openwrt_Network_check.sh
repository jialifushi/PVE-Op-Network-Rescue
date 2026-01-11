cat << 'EOF' > /root/uninstall_pppoe_watchdog.sh
#!/bin/sh
# ==========================================
# PPPoE 观测系统一键卸载脚本
# 功能：彻底清除钩子、日志及核心脚本
# ==========================================

BASE_DIR="/root/pppoe_watchdog"
WAN_HOTPLUG="/etc/hotplug.d/iface/99-wan-logger"
PPP_HOTPLUG="/etc/hotplug.d/ppp/99-ppp-logger"

echo "=========================================="
echo "    正在卸载 PPPoE 观测系统..."
echo "=========================================="

# 1. 移除 Hotplug 钩子 (拔掉系统的“眼睛”)
echo "[1/3] 正在移除 Hotplug 监控钩子..."
if [ -f "$WAN_HOTPLUG" ]; then
    rm -f "$WAN_HOTPLUG"
    echo "  -> 接口监控已移除。"
fi

if [ -f "$PPP_HOTPLUG" ]; then
    rm -f "$PPP_HOTPLUG"
    echo "  -> 拨号监控已移除。"
fi

# 2. 清理物理目录 (删除脚本与历史日志)
echo "[2/3] 正在清理物理文件及日志..."
if [ -d "$BASE_DIR" ]; then
    rm -rf "$BASE_DIR"
    echo "  -> 目录 $BASE_DIR 已删除。"
else
    echo "  -> 目录已不存在，跳过。"
fi

# 3. 验证卸载结果
echo "[3/3] 正在进行最后审计..."
if [ ! -d "$BASE_DIR" ] && [ ! -f "$WAN_HOTPLUG" ] && [ ! -f "$PPP_HOTPLUG" ]; then
    echo "=========================================="
    echo " [✓] 卸载成功！系统已恢复至部署前状态。"
    echo "=========================================="
else
    echo " [!] 卸载过程中似乎有残留，请手动检查。"
fi

# 自毁卸载脚本
rm -f "$0"
EOF

chmod +x /root/uninstall_pppoe_watchdog.sh
