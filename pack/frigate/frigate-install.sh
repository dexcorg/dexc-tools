#!/bin/bash
# ==============================================================
# Frigate｜一键安装脚本
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
echo "  Frigate｜一键安装脚本"
echo "========================================="
echo "[适用场景]
  服务器已安装 Ubuntu 22.04 + Docker，
  需要安装 Frigate 视频监控系统。"
echo ""
echo "[功能说明]
  自动完成以下操作：
  - 检测并选择用于存储监控视频的硬盘
  - 格式化硬盘（GPT + EXT4）并挂载
  - 检测 Coral TPU 硬件及驱动状态
  - 交互式收集 Frigate 安装参数
  - 创建 Docker 容器并安装 Frigate"
echo ""
echo "[操作方式]
  以 root 或 sudo 权限运行本脚本，按提示逐项输入参数。"
echo ""
echo "[执行步骤]
  1. 环境检测
  2. 硬盘检测与选择
  3. 硬盘格式化与挂载
  4. Coral 硬件检测
  5. 安装参数配置
  6. 安装 Frigate
  7. 安装结果"
echo ""
echo "[注意事项]
  - 需要 root 权限或 sudo 执行
  - 硬盘格式化为破坏性操作，数据不可恢复
  - 格式化前请确认硬盘中无重要数据
  - 需要 Docker 已安装"
echo "========================================="

read -p "[输入] 按回车开始安装，按 Ctrl+C 取消..."

# ========== 步骤 1/7：环境检测 ==========
echo ""
echo "[进度] 步骤 1/7：环境检测 ..."

# 检查 root 权限
if [ "$EUID" -ne 0 ]; then
  warn "当前非 root 用户，后续操作将使用 sudo"
fi

# 检查 Docker
if ! command -v docker &> /dev/null; then
  error "未检测到 Docker，请先安装 Docker"
  echo "[结束] 按回车键退出..."
  read
  exit 1
fi
ok "Docker 已安装：$(docker --version)"

# ========== 步骤 2/7：硬盘检测与选择 ==========
echo ""
echo "[进度] 步骤 2/7：硬盘检测与选择 ..."

# 获取所有块设备信息
DISKS=()
echo ""
info "检测到以下可用硬盘："
echo "-----------------------------------------"
printf "%-4s %-12s %-10s %-20s\n" "编号" "设备名" "大小" "已挂载"
echo "-----------------------------------------"

INDEX=1
while IFS= read -r line; do
  DEV_NAME=$(echo "$line" | awk '{print $1}')
  DEV_SIZE=$(echo "$line" | awk '{print $2}')
  MOUNT_POINT=$(lsblk -no MOUNTPOINT "/dev/$DEV_NAME" 2>/dev/null | head -1)
  if [ -z "$MOUNT_POINT" ]; then
    MOUNT_POINT="-"
  fi
  printf "%-4s %-12s %-10s %-20s\n" "$INDEX" "$DEV_NAME" "$DEV_SIZE" "$MOUNT_POINT"
  DISKS+=("$DEV_NAME")
  INDEX=$((INDEX + 1))
done < <(lsblk -dno NAME,SIZE,TYPE | awk '$3=="disk" {print $1, $2, $3}')

echo "-----------------------------------------"

if [ ${#DISKS[@]} -eq 0 ]; then
  error "未检测到可用硬盘"
  echo "[结束] 按回车键退出..."
  read
  exit 1
fi

# 用户选择
while true; do
  read -p "[输入] 请选择用于存储监控视频的硬盘编号 [1-${#DISKS[@]}]，输入 q 取消: " DISK_CHOICE
  if [[ "$DISK_CHOICE" == "q" || "$DISK_CHOICE" == "Q" ]]; then
    echo "[结束] 按回车键退出..."
    read
    exit 0
  fi
  if [[ "$DISK_CHOICE" =~ ^[0-9]+$ ]] && [ "$DISK_CHOICE" -ge 1 ] && [ "$DISK_CHOICE" -le "${#DISKS[@]}" ]; then
    SELECTED_DISK="${DISKS[$((DISK_CHOICE - 1))]}"
    ok "已选择硬盘：/dev/$SELECTED_DISK"
    break
  else
    error "输入无效，请重新输入"
  fi
done

# ========== 步骤 3/7：硬盘格式化与挂载 ==========
echo ""
echo "[进度] 步骤 3/7：硬盘格式化与挂载 ..."

# 显示选中硬盘详细信息
SELECTED_SIZE=$(lsblk -dno SIZE "/dev/$SELECTED_DISK" | xargs)
SELECTED_MODEL=$(lsblk -dno MODEL "/dev/$SELECTED_DISK" | xargs)
CURRENT_MOUNT=$(lsblk -no MOUNTPOINT "/dev/$SELECTED_DISK" 2>/dev/null | head -1)

echo ""
info "选中硬盘详情："
echo "  设备名：/dev/$SELECTED_DISK"
echo "  型  号：${SELECTED_MODEL:-未知}"
echo "  大  小：$SELECTED_SIZE"
echo "  挂载点：${CURRENT_MOUNT:-未挂载}"

# 检查是否已挂载
if [ -n "$CURRENT_MOUNT" ] && [ "$CURRENT_MOUNT" != "-" ]; then
  warn "该硬盘当前已挂载至 $CURRENT_MOUNT"
  warn "格式化将清除所有数据且卸载挂载点！"
fi

echo ""
warn "此操作将格式化硬盘，所有数据将被清除且不可恢复！"
read -p "[输入] 请输入硬盘名称作为确认（如 VDATA）: " DISK_NAME

if [ -z "$DISK_NAME" ]; then
  error "未输入硬盘名称，操作取消"
  echo "[结束] 按回车键退出..."
  read
  exit 1
fi

# 卸载已挂载的分区
EXISTING_PARTS=$(lsblk -rno NAME,MOUNTPOINT "/dev/$SELECTED_DISK" 2>/dev/null | awk '$2!="" && $2!="-" {print $1}')
for part in $EXISTING_PARTS; do
  MOUNT_PT=$(lsblk -no MOUNTPOINT "/dev/$part" 2>/dev/null | head -1)
  if [ -n "$MOUNT_PT" ] && [ "$MOUNT_PT" != "-" ]; then
    info "卸载分区 /dev/$part（挂载于 $MOUNT_PT）..."
    sudo umount "/dev/$part" || {
      error "卸载失败，请手动卸载后重试"
      echo "[结束] 按回车键退出..."
      read
      exit 1
    }
  fi
done

# 创建 GPT 分区表
info "创建 GPT 分区表..."
sudo parted "/dev/$SELECTED_DISK" --script mklabel gpt
ok "GPT 分区表创建完成"

# 创建分区
info "创建 EXT4 分区..."
sudo parted "/dev/$SELECTED_DISK" --script mkpart primary ext4 0% 100%
sudo partprobe "/dev/$SELECTED_DISK"
sleep 2
ok "分区创建完成"

# 查找实际分区设备名（原始模式解析，避免树形前缀）
ACTUAL_PART=$(lsblk -rno NAME,TYPE "/dev/$SELECTED_DISK" 2>/dev/null | awk '$2=="part"{print $1}' | head -n 1)
if [ -z "$ACTUAL_PART" ] || [ ! -b "/dev/$ACTUAL_PART" ]; then
  error "未找到新创建的分区，请检查磁盘"
  echo "[结束] 按回车键退出..."
  read
  exit 1
fi
info "格式化分区 /dev/$ACTUAL_PART 为 EXT4..."
sudo mkfs.ext4 -F "/dev/$ACTUAL_PART"
ok "格式化完成"

# 创建挂载点
info "创建挂载点 /mnt/$DISK_NAME ..."
sudo mkdir -p "/mnt/$DISK_NAME"
ok "挂载点创建完成"

# 挂载
info "挂载硬盘至 /mnt/$DISK_NAME ..."
sudo mount "/dev/$ACTUAL_PART" "/mnt/$DISK_NAME"
ok "挂载完成"

# 写入 fstab（重启自动挂载）
info "写入 /etc/fstab 实现重启自动挂载..."
FSTAB_LINE="UUID=$(blkid -s UUID -o value "/dev/$ACTUAL_PART") /mnt/$DISK_NAME ext4 defaults 0 2"
if ! grep -q "/mnt/$DISK_NAME" /etc/fstab; then
  echo "$FSTAB_LINE" | sudo tee -a /etc/fstab > /dev/null
  ok "fstab 写入完成"
else
  ok "fstab 中已存在该挂载配置"
fi

# 创建 Frigate 目录结构
info "创建 Frigate 存储与配置目录..."
sudo mkdir -p "/mnt/$DISK_NAME/frigate/storage"
sudo mkdir -p "/mnt/$DISK_NAME/frigate/config"
ok "目录结构创建完成"

# ========== 步骤 4/7：Coral 硬件检测 ==========
echo ""
echo "[进度] 步骤 4/7：Coral 硬件检测 ..."

CORAL_HARDWARE=false
CORAL_DRIVER=false
CORAL_DEVICE=false
CORAL_LIB=false

# 检查硬件
if lspci 2>/dev/null | grep -q "Coral"; then
  CORAL_HARDWARE=true
  ok "检测到 Coral PCIe 硬件"
else
  info "未检测到 Coral PCIe 硬件"
fi

# 检查驱动模块
if lsmod 2>/dev/null | grep -q "gasket" && lsmod 2>/dev/null | grep -q "apex"; then
  CORAL_DRIVER=true
  ok "Coral 驱动模块已加载"
fi

# 检查设备节点
if [ -e /dev/apex_0 ]; then
  CORAL_DEVICE=true
  ok "Coral 设备节点已就绪"
fi

# 检查动态链接库
if ls /usr/lib/x86_64-linux-gnu/libedgetpu.so* 2>/dev/null | grep -q .; then
  CORAL_LIB=true
  ok "Coral 动态链接库已安装"
fi

# 综合判断
echo ""
if [ "$CORAL_HARDWARE" = true ] && [ "$CORAL_DRIVER" = true ] && [ "$CORAL_DEVICE" = true ] && [ "$CORAL_LIB" = true ]; then
  CORAL_STATUS="ready"
  ok "Coral TPU 就绪，Frigate 将启用 AI 加速检测"
elif [ "$CORAL_HARDWARE" = true ]; then
  CORAL_STATUS="need_driver"
  warn "检测到 Coral 硬件但驱动未就绪"
  warn "请先执行 install-coral-pcie.sh 安装驱动并重启服务器"
  warn "当前安装将跳过 Coral 相关配置"
else
  CORAL_STATUS="none"
  info "未检测到 Coral 硬件，Frigate 将使用 CPU 检测"
fi

# ========== 步骤 5/7：安装参数配置 ==========
echo ""
echo "[进度] 步骤 5/7：安装参数配置 ..."

# 默认值
CONTAINER_NAME="frigate"
WEB_PORT="8971"
RTSP_PORT="8554"
WEBRTC_PORT="8555"
SHM_SIZE="1g"
RTSP_PASSWORD=""
TIMEZONE="Asia/Shanghai"
IMAGE="ghcr.io/blakeblackshear/frigate:stable"

# 逐项输入
echo ""
read -p "[输入] (1/8) 容器名称 [回车使用默认值: frigate]: " INPUT
CONTAINER_NAME="${INPUT:-$CONTAINER_NAME}"

read -p "[输入] (2/8) Web 端口 [回车使用默认值: 8971]: " INPUT
WEB_PORT="${INPUT:-$WEB_PORT}"

read -p "[输入] (3/8) RTSP 端口 [回车使用默认值: 8554]: " INPUT
RTSP_PORT="${INPUT:-$RTSP_PORT}"

read -p "[输入] (4/8) WebRTC 端口 [回车使用默认值: 8555]: " INPUT
WEBRTC_PORT="${INPUT:-$WEBRTC_PORT}"

read -p "[输入] (5/8) 共享内存大小（如 1g、512m）[回车使用默认值: 1g]: " INPUT
SHM_SIZE="${INPUT:-$SHM_SIZE}"

while true; do
  read -p "[输入] (6/8) RTSP 密码（必填）: " RTSP_PASSWORD
  if [ -n "$RTSP_PASSWORD" ]; then
    break
  fi
  error "RTSP 密码不能为空"
done

read -p "[输入] (7/8) 时区 [回车使用默认值: Asia/Shanghai]: " INPUT
TIMEZONE="${INPUT:-$TIMEZONE}"

read -p "[输入] (8/8) 镜像地址 [回车使用默认值: ghcr.io/blakeblackshear/frigate:stable]: " INPUT
IMAGE="${INPUT:-$IMAGE}"

# 回显所有参数
echo ""
echo "========================================="
echo "[提示] 请确认以下安装参数："
echo "========================================="
echo "  容器名称：$CONTAINER_NAME"
echo "  Web 端口：$WEB_PORT"
echo "  RTSP 端口：$RTSP_PORT"
echo "  WebRTC 端口：$WEBRTC_PORT"
echo "  共享内存：$SHM_SIZE"
echo "  RTSP 密码：$RTSP_PASSWORD"
echo "  时  区：$TIMEZONE"
echo "  镜像地址：$IMAGE"
echo "  存储路径：/mnt/$DISK_NAME/frigate/storage"
echo "  配置路径：/mnt/$DISK_NAME/frigate/config"
echo "  Coral 状态：$CORAL_STATUS"
echo "========================================="

while true; do
  read -p "[输入] 确认以上参数无误？[y/n]: " CONFIRM
  case "$CONFIRM" in
    y|Y) break ;;
    n|N)
      warn "安装已取消"
      echo "[结束] 按回车键退出..."
      read
      exit 0
      ;;
    *)
      error "请输入 y 或 n"
      ;;
  esac
done

# ========== 步骤 6/7：安装 Frigate ==========
echo ""
echo "[进度] 步骤 6/7：安装 Frigate ..."

# 检查容器是否已存在
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
  warn "容器 $CONTAINER_NAME 已存在"
  read -p "[输入] 是否删除旧容器并重新安装？[y/n]: " REINSTALL
  if [[ "$REINSTALL" == "y" || "$REINSTALL" == "Y" ]]; then
    docker stop "$CONTAINER_NAME" 2>/dev/null || true
    docker rm "$CONTAINER_NAME" 2>/dev/null || true
    ok "旧容器已删除"
  else
    warn "保留现有容器，安装取消"
    echo "[结束] 按回车键退出..."
    read
    exit 0
  fi
fi

# 构建 docker run 呼叫
DOCKER_CMD="docker run -d"
DOCKER_CMD="$DOCKER_CMD --name $CONTAINER_NAME"
DOCKER_CMD="$DOCKER_CMD --restart=unless-stopped"
DOCKER_CMD="$DOCKER_CMD --stop-timeout 30"
DOCKER_CMD="$DOCKER_CMD --mount type=tmpfs,target=/tmp/cache,tmpfs-size=8000000000"
DOCKER_CMD="$DOCKER_CMD --shm-size=$SHM_SIZE"
DOCKER_CMD="$DOCKER_CMD -v /mnt/$DISK_NAME/frigate/storage:/media/frigate"
DOCKER_CMD="$DOCKER_CMD -v /mnt/$DISK_NAME/frigate/config:/config"
DOCKER_CMD="$DOCKER_CMD -v /etc/localtime:/etc/localtime:ro"
DOCKER_CMD="$DOCKER_CMD -e FRIGATE_RTSP_PASSWORD='$RTSP_PASSWORD'"
DOCKER_CMD="$DOCKER_CMD -e TZ='$TIMEZONE'"
DOCKER_CMD="$DOCKER_CMD -p $WEB_PORT:8971"
DOCKER_CMD="$DOCKER_CMD -p $RTSP_PORT:8554"
DOCKER_CMD="$DOCKER_CMD -p $WEBRTC_PORT:8555/tcp"
DOCKER_CMD="$DOCKER_CMD -p $WEBRTC_PORT:8555/udp"

# Coral 设备
if [ "$CORAL_STATUS" = "ready" ]; then
  DOCKER_CMD="$DOCKER_CMD --device /dev/dri/renderD128"
  DOCKER_CMD="$DOCKER_CMD --device /dev/apex_0"
  DOCKER_CMD="$DOCKER_CMD -v /usr/lib/x86_64-linux-gnu/libedgetpu.so.1.0:/usr/lib/x86_64-linux-gnu/libedgetpu.so.1.0:ro"
  DOCKER_CMD="$DOCKER_CMD -v /usr/lib/x86_64-linux-gnu/libedgetpu.so.1:/usr/lib/x86_64-linux-gnu/libedgetpu.so.1:ro"
  DOCKER_CMD="$DOCKER_CMD -e LD_LIBRARY_PATH=/usr/lib/x86_64-linux-gnu"
fi

DOCKER_CMD="$DOCKER_CMD $IMAGE"

# 执行安装
info "正在拉取镜像并创建容器..."
eval "$DOCKER_CMD"

# 验证容器状态
sleep 3
if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
  ok "Frigate 容器启动成功"
else
  error "Frigate 容器启动失败"
  info "请检查日志：docker logs $CONTAINER_NAME"
  echo "[结束] 按回车键退出..."
  read
  exit 1
fi

# ========== 步骤 7/7：安装结果 ==========
echo ""
echo "[进度] 步骤 7/7：安装结果 ..."

# 获取服务器 IP
SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
if [ -z "$SERVER_IP" ]; then
  SERVER_IP="<服务器IP地址>"
fi

echo ""
echo "========================================="
echo "[结果] Frigate 安装完成！"
echo "========================================="
echo ""
echo "  容器名称：$CONTAINER_NAME"
echo "  访问地址：https://$SERVER_IP:$WEB_PORT"
echo "  配置目录：/mnt/$DISK_NAME/frigate/config"
echo "  存储目录：/mnt/$DISK_NAME/frigate/storage"
echo ""
echo "  [重要] 请执行以下命令获取 admin 密码："
echo "    docker logs $CONTAINER_NAME 2>&1 | grep 'Password'"
echo ""
echo "  [下一步] 请使用 frigate-config 工具生成 config.yaml 配置文件，"
echo "  然后上传至 /mnt/$DISK_NAME/frigate/config/ 目录并重启容器。"
echo ""
echo "========================================="
echo ""
echo "[结束] 按回车键退出..."
read
