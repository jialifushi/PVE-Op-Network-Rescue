## 部署方式

**第一步：下载两个脚本到同一目录**

```bash
mkdir -p /opt/pve-watchdog
cd /opt/pve-watchdog
# 将 pve_watchdog.sh 和 deploy_pve_watchdog.sh 上传/复制到此目录
```

**第二步：赋予执行权限**

```bash
chmod +x /opt/pve-watchdog/pve_watchdog.sh
chmod +x /opt/pve-watchdog/deploy_pve_watchdog.sh
```

**第三步：执行部署**

```bash
bash /opt/pve-watchdog/deploy_pve_watchdog.sh
```

完成，部署脚本会自动完成以下所有操作：
- 将主脚本复制到 `/usr/local/bin/pve_watchdog.sh`
- 创建并启用 systemd 服务（开机自启）
- 立即启动守护进程

---

**验证是否成功运行：**

```bash
# 查看服务状态
systemctl status pve-watchdog

# 查看实时日志（应看到"启动"日志）
tail -f /var/log/pve_watchdog.log
```

---

> `/opt/pve-watchdog/` 目录部署后可以保留也可以删除，主脚本已被复制到 `/usr/local/bin/`，服务不依赖原目录。


**卸载脚本使用方式：**

```bash
chmod +x /opt/pve-watchdog/uninstall_pve_watchdog.sh
bash /opt/pve-watchdog/uninstall_pve_watchdog.sh
```

卸载脚本会清除以下所有内容：

| 项目 | 路径 |
|---|---|
| systemd 服务 | `/etc/systemd/system/pve-watchdog.service` |
| 主脚本 | `/usr/local/bin/pve_watchdog.sh` |
| 日志文件 | `/var/log/pve_watchdog.log` |
| 冷却时间戳 | `/var/run/pve_watchdog_last_reboot.ts` |
| 残留进程 | `pgrep` 强制 kill |

执行完毕后系统与安装前完全一致，`systemctl status pve-watchdog` 会提示服务不存在。
