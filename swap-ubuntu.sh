#!/bin/bash

# 获取当前内存大小（单位为KB）
current_mem=$(free -k | awk '/Mem:/ {print $2}')

# 将内存大小转换为MB，并向下取整
current_mem_mb=$((current_mem / 1024))

# 检查swap是否已存在，如果存在则删除
if [[ -f /swapfile ]]; then
  sudo swapoff /swapfile
  sudo rm /swapfile
fi

# 创建与内存大小相同的swap文件 (单位为MB)
sudo fallocate -l ${current_mem_mb}M /swapfile

# 设置正确的权限
sudo chmod 600 /swapfile

# 格式化为swap
sudo mkswap /swapfile

# 启用swap
sudo swapon /swapfile

# 将swap配置添加到/etc/fstab，以便在重启后自动启用
echo "/swapfile none swap sw 0 0" | sudo tee -a /etc/fstab

echo "Swap file created and activated. Size: ${current_mem_mb}MB"

# 可选：再次运行 free -h 命令查看swap是否已启用
free -h
