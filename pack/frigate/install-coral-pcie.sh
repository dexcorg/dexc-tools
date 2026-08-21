#!/bin/bash
# ==============================================================
# Google Coral PCIe TPU 驱动安装脚本
# 版本 1.0
# ==============================================================

set -e

# ---------- 颜色输出 ----------
info()  { echo -e "\033[1;34m[提示]\033[0m $1"; }
ok()    { echo -e "\033[1;32m[完成]\033[0m $1"; }
warn()  { echo -e "\033[1;33m[警告]\033[0m $1"; }
error() { echo -e "\033[1;31m[错误]\033[0m $1"; }

# ---------- 启动说明 ----------
echo "========================================="
echo "  Google Coral PCIe TPU 驱动安装"
echo "========================================="
echo "[适用场景]
  服务器已插入 Google Coral PCIe TPU 硬件，
  安装驱动与运行时环境"
echo ""
echo "[功能说明]
  自动完成以下操作：
  - 检测操作系统类型（Ubuntu / Debian）
  - 添加 Coral 官方软件源
  - 安装 gasket 内核驱动
  - 安装 Edge TPU 运行时库
  - 验证驱动安装结果"
echo ""
echo "[操作方式]
  以 root 或 sudo 权限运行本脚本，按提示确认即可。"
echo ""
echo "[执行步骤]
  1. 系统检测
  2. 更新系统软件包
  3. 添加 Coral 官方软件源
  4. 安装 gasket 驱动
  5. 安装 Edge TPU 运行时
  6. 验证安装结果"
echo ""
echo "[注意事项]
  - 需要 root 权限或 sudo 执行
  - 安装完成后需要重启服务器才能生效
  - 请确保 Coral PCIe TPU 已正确插入主板插槽"
echo "========================================="

read -p "[输入] 按回车开始安装，按 Ctrl+C 取消..."

# ========== 步骤 1/6：系统检测 ==========
echo ""
echo "[进度] 步骤 1/6：系统检测 ..."

OS_TYPE=""
OS_VERSION=""

if [ -f /etc/os-release ]; then
  . /etc/os-release
  OS_TYPE="$ID"
  OS_VERSION="$VERSION_ID"
fi

case "$OS_TYPE" in
  ubuntu)
    ok "检测到系统：Ubuntu $OS_VERSION"
    ;;
  debian)
    ok "检测到系统：Debian $OS_VERSION"
    ;;
  *)
    warn "检测到非 Ubuntu/Debian 系统（$OS_TYPE），脚本可能无法正常运行。"
    read -p "[输入] 是否继续？(y/n): " ans
    if [[ "$ans" != "y" && "$ans" != "Y" ]]; then
      echo "[结束] 按回车键退出..."
      read
      exit 1
    fi
    ;;
esac

# ========== 步骤 2/6：更新系统软件包 ==========
echo ""
echo "[进度] 步骤 2/6：更新系统软件包 ..."

sudo apt update -y
sudo apt upgrade -y
sudo apt install -y dkms git curl build-essential lsb-release gnupg

ok "系统软件包更新完成"

# ========== 步骤 3/6：添加 Coral 官方软件源 ==========
echo ""
echo "[进度] 步骤 3/6：添加 Coral 官方软件源 ..."

CORAL_LIST="/etc/apt/sources.list.d/coral-edgetpu.list"

if [ -f "$CORAL_LIST" ]; then
  ok "Coral 软件源已存在，跳过添加"
else
  case "$OS_TYPE" in
    ubuntu)
      echo "deb https://packages.cloud.google.com/apt coral-edgetpu-stable main" | sudo tee "$CORAL_LIST"
      curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -
      ;;
    debian)
      echo "deb https://packages.cloud.google.com/apt coral-edgetpu-stable main" | sudo tee "$CORAL_LIST" > /dev/null
      curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo gpg --dearmor -o /usr/share/keyrings/coral-archive-keyring.gpg
      echo "deb [signed-by=/usr/share/keyrings/coral-archive-keyring.gpg] https://packages.cloud.google.com/apt coral-edgetpu-stable main" | sudo tee "$CORAL_LIST" > /dev/null
      ;;
  esac
  sudo apt update -y
  ok "Coral 软件源添加完成"
fi

# ========== 步骤 4/6：安装 gasket 驱动 ==========
echo ""
echo "[进度] 步骤 4/6：安装 gasket 驱动 ..."

if dpkg -l | grep -q gasket-dkms; then
  ok "gasket-dkms 已安装，跳过"
else
  sudo apt install -y gasket-dkms || {
    warn "默认源安装失败，尝试从 Coral 仓库安装..."
    sudo apt install -y gasket-dkms -t coral-edgetpu-stable || {
      error "gasket-dkms 安装失败"
      echo "[结束] 按回车键退出..."
      read
      exit 1
    }
  }
  ok "gasket 驱动安装完成"
fi

# ========== 步骤 5/6：安装 Edge TPU 运行时 ==========
echo ""
echo "[进度] 步骤 5/6：安装 Edge TPU 运行时 ..."

if dpkg -l | grep -q libedgetpu1-std; then
  ok "libedgetpu1-std 已安装，跳过"
else
  sudo apt install -y libedgetpu1-std python3-pycoral || {
    warn "默认源安装失败，尝试从 Coral 仓库安装..."
    sudo apt install -y libedgetpu1-std python3-pycoral -t coral-edgetpu-stable || {
      error "Edge TPU 运行时安装失败"
      echo "[结束] 按回车键退出..."
      read
      exit 1
    }
  }
  ok "Edge TPU 运行时安装完成"
fi

# ========== 步骤 6/6：验证安装结果 ==========
echo ""
echo "[进度] 步骤 6/6：验证安装结果 ..."

PASS_COUNT=0
TOTAL_COUNT=4

# 加载内核模块
sudo modprobe gasket || true
sudo modprobe apex || true

# 检查硬件识别
echo ""
info "检查硬件识别..."
if lspci | grep -q "Coral"; then
  ok "已检测到 Coral 设备"
  lspci | grep "Coral"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  warn "未检测到 Coral 设备，请检查硬件连接"
fi

# 检查驱动模块
info "检查驱动模块..."
if lsmod | grep -q "gasket" && lsmod | grep -q "apex"; then
  ok "驱动模块已加载：gasket + apex"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  warn "驱动模块未完全加载，可能需要重启"
fi

# 检查设备节点
info "检查设备节点..."
if [ -e /dev/apex_0 ]; then
  ok "设备节点已生成：/dev/apex_0"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  warn "未找到 /dev/apex_0，可能需要重启"
fi

# 检查动态链接库
info "检查动态链接库..."
if ls /usr/lib/x86_64-linux-gnu/libedgetpu.so* 2>/dev/null | grep -q .; then
  ok "动态链接库已安装"
  ls /usr/lib/x86_64-linux-gnu/libedgetpu.so*
  PASS_COUNT=$((PASS_COUNT + 1))
else
  warn "未找到 libedgetpu 动态链接库"
fi

# 汇总
echo ""
echo "========================================="
echo "[结果] 验证完成。"
echo "  通过：${PASS_COUNT}/${TOTAL_COUNT}"
if [ "$PASS_COUNT" -lt "$TOTAL_COUNT" ]; then
  echo "  部分检查未通过，建议重启服务器后重新验证。"
fi
echo "========================================="
echo ""
echo "[提示] 安装完成后请执行 sudo reboot 重启服务器，重启后可通过以下命令再次验证："
echo "  lspci | grep Coral"
echo "  lsmod | grep -E 'gasket|apex'"
echo "  ls -l /dev/apex_*"
echo "  ls -l /usr/lib/x86_64-linux-gnu/libedgetpu.so*"
echo ""
echo "[结束] 按回车键退出..."
read
