ssh-keygen -t rsa -b 2048 -N "" -f ~/.ssh/id_rsa
ssh-copy-id root@192.168.10.1
ssh root@192.168.10.1 "echo 成功"
