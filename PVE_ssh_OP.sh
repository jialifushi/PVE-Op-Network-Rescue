# 两个脚本的联动前提确保pve ssh免密操作openwrt

# 1、生成密钥对
ssh-keygen -t rsa -b 2048 -N "" -f ~/.ssh/id_rsa
# 2、复制密钥到Openwrt
ssh-copy-id root@192.168.10.1

如果再复制密钥进入openwrt报错如下：
root@iHert:~# ssh-copy-id root@192.168.10.1
/usr/bin/ssh-copy-id: INFO: Source of key(s) to be installed: "/root/.ssh/id_rsa.pub"
/usr/bin/ssh-copy-id: INFO: attempting to log in with the new key(s), to filter out any that are already installed

/usr/bin/ssh-copy-id: ERROR: @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
ERROR: @    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
ERROR: @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
ERROR: IT IS POSSIBLE THAT SOMEONE IS DOING SOMETHING NASTY!
ERROR: Someone could be eavesdropping on you right now (man-in-the-middle attack)!
ERROR: It is also possible that a host key has just been changed.
ERROR: The fingerprint for the RSA key sent by the remote host is
ERROR: SHA256:VkXaUDlhthX3Tfb1iyb9D8U3N2Wl+590wABjNbTBc30.
ERROR: Please contact your system administrator.
ERROR: Add correct host key in /root/.ssh/known_hosts to get rid of this message.
ERROR: Offending RSA key in /etc/ssh/ssh_known_hosts:2
ERROR:   remove with:
ERROR:   ssh-keygen -f "/etc/ssh/ssh_known_hosts" -R "192.168.10.1"
ERROR: Host key for 192.168.10.1 has changed and you have requested strict checking.
ERROR: Host key verification failed.

意味着：PVE 以前记录过 IP 为 192.168.10.1 的设备的“指纹”，但现在这个 IP 对应的设备（OpenWrt）指纹变了。这通常是因为你最近频繁重启、重装或修改了 OpenWrt，导致它的 SSH 密钥对重置了。

因此：
🛠️ 解决方案：清除“旧指纹”
你只需要在 PVE 终端执行以下两条命令，清除掉过期的记录，然后再重新发送密钥即可。
通常指纹记录在了系统全局配置 /etc/ssh/ssh_known_hosts 中

# 清理个人记录
ssh-keygen -f "/root/.ssh/known_hosts" -R "192.168.10.1"

# 清理系统全局记录（你的报错明确指出了这一行）
ssh-keygen -f "/etc/ssh/ssh_known_hosts" -R "192.168.10.1"

# 重新执行免密拷贝
ssh-copy-id root@192.168.10.1

# 如果能直接进入 OpenWrt 而不需要输密码，说明“特效药”脚本的前提条件就彻底打通了
ssh root@192.168.10.1 "echo 成功"
