#!/bin/bash

# 检查是否以root权限运行
if [[ $EUID -ne 0 ]]; then
   echo "此脚本需要root权限运行"
   echo "请使用: sudo $0"
   exit 1
fi

# 默认swap文件路径
SWAP_FILE="${1:-/swapfile}"

# 检查现有的swap
echo "检查系统现有swap状态..."
if swapon --show | grep -q '^/'; then
    echo "检测到系统已存在swap:"
    swapon --show
    read -p "是否继续创建新的swap? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "操作已取消"
        exit 0
    fi
fi

# 获取当前内存大小（单位为KB）
current_mem_kb=$(free -k | awk '/Mem:/ {print $2}')

# 将内存大小转换为MB
current_mem_mb=$((current_mem_kb / 1024))

# 计算swap大小：确保至少等于内存大小，并向上取整到最接近的128MB
swap_size_mb=$(( ((current_mem_mb + 127) / 128) * 128 ))

echo "系统内存: ${current_mem_mb}MB"
echo "计划创建的swap大小: ${swap_size_mb}MB"
echo "Swap文件路径: ${SWAP_FILE}"

# 检查swap文件是否已存在
if [[ -f "${SWAP_FILE}" ]]; then
    echo "检测到swap文件已存在: ${SWAP_FILE}"
    if swapoff "${SWAP_FILE}" 2>/dev/null; then
        echo "已停用现有swap文件"
    fi
    if rm "${SWAP_FILE}"; then
        echo "已删除现有swap文件"
    else
        echo "删除swap文件失败: ${SWAP_FILE}"
        exit 1
    fi
fi

# 检查目标目录是否存在
SWAP_DIR=$(dirname "${SWAP_FILE}")
if [[ ! -d "${SWAP_DIR}" ]]; then
    echo "创建swap文件目录: ${SWAP_DIR}"
    mkdir -p "${SWAP_DIR}" || { echo "创建目录失败"; exit 1; }
fi

echo "正在创建swap文件..."
# 创建swap文件 (单位为MB)
fallocate -l ${swap_size_mb}M "${SWAP_FILE}" || { 
    echo "使用fallocate创建失败，尝试使用dd命令..."
    dd if=/dev/zero of="${SWAP_FILE}" bs=1M count=${swap_size_mb} || { 
        echo "创建swap文件失败"; 
        exit 1; 
    }
}

# 设置正确的权限
chmod 600 "${SWAP_FILE}" || { echo "设置权限失败"; exit 1; }

# 格式化为swap
mkswap "${SWAP_FILE}" || { echo "格式化swap失败"; exit 1; }

# 启用swap
swapon "${SWAP_FILE}" || { echo "启用swap失败"; exit 1; }

# 从fstab中移除旧的swap配置
sed -i '/.*swap.*sw.*/d' /etc/fstab

# 添加新的swap配置到fstab
echo "${SWAP_FILE} none swap sw 0 0" | tee -a /etc/fstab || { echo "更新fstab失败"; exit 1; }

echo "Swap文件创建并激活成功！"
echo "大小: ${swap_size_mb}MB"
echo "路径: ${SWAP_FILE}"
echo -e "\n当前系统内存使用情况："
free -h

# 显示swap的详细信息
echo -e "\nSwap详细信息："
swapon --show
