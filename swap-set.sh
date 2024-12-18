#!/bin/bash

# 检查是否以root权限运行
if [[ $EUID -ne 0 ]]; then
   echo "此脚本需要root权限运行"
   echo "请使用: sudo $0"
   exit 1
fi

# 检测Linux发行版
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_NAME=$ID
    OS_VERSION=$VERSION_ID
else
    OS_NAME=$(uname -s)
    OS_VERSION=$(uname -r)
fi

echo "检测到系统: $OS_NAME $OS_VERSION"

# 安装必要的包
install_packages() {
    echo "正在安装必要的工具包..."
    case $OS_NAME in
        "ubuntu"|"debian")
            apt-get update -qq
            apt-get install -y util-linux procps
            ;;
        "centos"|"rhel"|"fedora")
            if command -v dnf >/dev/null 2>&1; then
                dnf install -y util-linux procps
            else
                yum install -y util-linux procps
            fi
            ;;
        "alpine")
            apk add --no-cache util-linux procps
            ;;
        "opensuse"*|"sles")
            zypper install -y util-linux procps
            ;;
        *)
            echo "警告: 未知的发行版，请手动安装 util-linux 和 procps 包"
            ;;
    esac
}

# 检查必要命令是否存在
MISSING_COMMANDS=()
for cmd in free fallocate mkswap swapon; do
    if ! command -v $cmd >/dev/null 2>&1; then
        MISSING_COMMANDS+=($cmd)
    fi
done

# 如果有缺失的命令，尝试安装
if [ ${#MISSING_COMMANDS[@]} -ne 0 ]; then
    echo "以下命令未找到: ${MISSING_COMMANDS[*]}"
    echo "尝试安装必要的包..."
    install_packages
    
    # 再次检查命令是否已安装
    for cmd in "${MISSING_COMMANDS[@]}"; do
        if ! command -v $cmd >/dev/null 2>&1; then
            echo "错误: 无法安装命令 '$cmd'"
            exit 1
        fi
    done
    echo "所需工具包安装完成"
fi

# 默认swap文件路径
SWAP_FILE="${1:-/swapfile}"

# 检查文件系统类型
SWAP_DIR=$(dirname "${SWAP_FILE}")
FS_TYPE=$(df -T "${SWAP_DIR}" | awk 'NR==2 {print $2}')
echo "检测到文件系统类型: $FS_TYPE"

# 某些文件系统不支持fallocate
UNSUPPORTED_FS="btrfs|nfs|tmpfs|zfs"
USE_DD=0
if echo "$FS_TYPE" | grep -qE "$UNSUPPORTED_FS"; then
    echo "警告: $FS_TYPE 文件系统可能不支持fallocate，将使用dd命令"
    USE_DD=1
fi

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

# 获取系统内存信息
if [ -f /proc/meminfo ]; then
    current_mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
else
    current_mem_kb=$(free -k | awk '/Mem:/ {print $2}')
fi

# 将内存大小转换为MB
current_mem_mb=$((current_mem_kb / 1024))

# 计算swap大小：确保至少等于内存大小，并向上取整到最接近的128MB
swap_size_mb=$(( ((current_mem_mb + 127) / 128) * 128 ))

echo "系统内存: ${current_mem_mb}MB"
echo "计划创建的swap大小: ${swap_size_mb}MB"
echo "Swap文件路径: ${SWAP_FILE}"

# 检查磁盘空间
available_space_mb=$(df -BM "${SWAP_DIR}" | awk 'NR==2 {gsub("M",""); print $4}')
if [ ${available_space_mb} -lt ${swap_size_mb} ]; then
    echo "错误: 磁盘空间不足"
    echo "需要: ${swap_size_mb}MB"
    echo "可用: ${available_space_mb}MB"
    exit 1
fi

# 检查并处理现有swap文件
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

# 检查并创建目标目录
SWAP_DIR=$(dirname "${SWAP_FILE}")
if [[ ! -d "${SWAP_DIR}" ]]; then
    echo "创建swap文件目录: ${SWAP_DIR}"
    mkdir -p "${SWAP_DIR}" || { echo "创建目录失败"; exit 1; }
fi

echo "正在创建swap文件..."
# 根据文件系统类型选择创建方法
if [ $USE_DD -eq 1 ]; then
    echo "使用dd命令创建swap文件..."
    dd if=/dev/zero of="${SWAP_FILE}" bs=1M count=${swap_size_mb} status=progress || {
        echo "创建swap文件失败"
        exit 1
    }
else
    fallocate -l ${swap_size_mb}M "${SWAP_FILE}" || {
        echo "fallocate失败，尝试使用dd命令..."
        dd if=/dev/zero of="${SWAP_FILE}" bs=1M count=${swap_size_mb} status=progress || {
            echo "创建swap文件失败"
            exit 1
        }
    }
fi

# 设置权限
chmod 600 "${SWAP_FILE}" || { echo "设置权限失败"; exit 1; }

# 格式化为swap
mkswap "${SWAP_FILE}" || { echo "格式化swap失败"; exit 1; }

# 启用swap
swapon "${SWAP_FILE}" || { echo "启用swap失败"; exit 1; }

# 更新fstab配置
# 首先备份fstab
cp /etc/fstab /etc/fstab.bak
echo "已备份 /etc/fstab 到 /etc/fstab.bak"

# 从fstab中移除旧的swap配置
sed -i '/.*swap.*sw.*/d' /etc/fstab

# 添加新的swap配置
echo "${SWAP_FILE} none swap sw 0 0" | tee -a /etc/fstab || { 
    echo "更新fstab失败"
    cp /etc/fstab.bak /etc/fstab
    echo "已恢复fstab备份"
    exit 1
}

echo "Swap文件创建并激活成功！"
echo "大小: ${swap_size_mb}MB"
echo "路径: ${SWAP_FILE}"
echo -e "\n当前系统内存使用情况："
free -h

# 显示swap的详细信息
echo -e "\nSwap详细信息："
swapon --show

# 显示系统swap相关参数
echo -e "\nSwap系统参数："
cat /proc/sys/vm/swappiness 2>/dev/null || echo "无法读取swappiness值"
