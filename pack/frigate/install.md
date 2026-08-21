1. 安装 Ubuntu 系统。推荐 22.04 版本以及最小安装。

2. 安装宝塔面板，以及 LNMP + Docker 运行环境。

3. 通过宝塔面板放行端口，推荐开放以下端口：
   8971 入站 ... frigate_web
   8554 入站 ... frigate_rtsp
   8555 双向 ... frigate_webrtc

4. 确保系统中存在另一块用于存储监控视频的硬盘。如果不存在需要关机、连接磁盘后再执行后续步骤。

5. 确认系统中是否存在 Coral 硬件设备。如果存在需要首先执行 [install-coral-pcie.sh] 脚本（脚本自动判断操作系统类型并安装驱动）。安装完成后重启服务器再执行后续步骤。
   重启后可以通过以下命令确认 Coral 驱动安装结果。
   ```sh
   # 检查硬件识别
   lspci | grep "Coral"
   # 检查驱动模块
   lsmod | grep -E "gasket|apex"
   # 检查设备节点
   ls -l /dev/apex_*
   # 检查动态链接库
   ls -l /usr/lib/x86_64-linux-gnu/libedgetpu.so*
   ```

6. 执行 [install.sh] 根据提示进行安装：
   1. 脚本自动检测硬盘并给出列表，需要选中用于存储监控视频的硬盘编号
   2. 输入硬盘名称（如 "VDATA"）脚本会使用最佳配置对该硬盘进行格式化（GPT + EXT4）并挂载至 "/mnt/硬盘名称"。此挂载重启有效
   3. 脚本会自动检测 Coral 硬件以及驱动是否存在，给出提示
   4. 连续输入 Frigate 安装参数：容器名称、端口配置（默认使用步骤3中定义的端口，如果修改需统一）、内存、存储路径、配置文件路径、RTSP密码、时区、镜像地址等
   5. 脚本给出安装摘要，确认无误后输入 y 执行安装
   6. 脚本根据参数创建 docker 命令并安装 Frigate。
   7. 安装完成后给出 Frigate 安装信息

7. 查看 Frigate 日志，找到 admin 密码并妥善保管

8. 本地主机上打开 frigate-config 工具，输入参数（是否启用Coral、摄像头信息及配置等）生成 config.yaml 配置文件。然后将生成的配置文件上传到服务器 Frigate 配置目录中。

9. 重启 Frigate 容器。访问 https://<IP地址>:8971 通过 admin + 密码登录管理面板查看运行状态。

10. 通过宝塔面板添加以下两个计划任务：
    1. Frigate 日志清理（每天触发1次）
    ```sh
    #!/bin/bash

    # ==============================
    # 常量定义
    # ==============================

    CONTAINER_NAME="frigate"
    MAX_LOG_SIZE=409600000   # 单位：字节

    # ==============================
    # 获取容器日志文件路径
    # ==============================

    LOG_PATH=$(docker inspect --format='{{.LogPath}}' "$CONTAINER_NAME" 2>/dev/null)

    if [ -z "$LOG_PATH" ]; then
    echo "容器不存在或未运行: $CONTAINER_NAME"
    exit 1
    fi

    if [ ! -f "$LOG_PATH" ]; then
    echo "未找到日志文件: $LOG_PATH"
    exit 1
    fi

    # ==============================
    # 获取日志文件大小
    # ==============================

    LOG_SIZE=$(stat -c%s "$LOG_PATH")

    # ==============================
    # 判断并清空日志
    # ==============================

    if [ "$LOG_SIZE" -gt "$MAX_LOG_SIZE" ]; then
    echo "日志大小 $LOG_SIZE 字节超过限制，正在清空..."
    truncate -s 0 "$LOG_PATH"
    echo "日志已清空"
    else
    echo "日志大小 $LOG_SIZE 字节未超过限制，无需处理"
    fi
    ```

    2. Frigate 自动重启（每15分钟触发1次）
    ```sh
    #!/bin/bash

    CONTAINER_NAME="frigate"

    # 检查容器是否在运行
    RUNNING=$(docker ps --filter "name=^/${CONTAINER_NAME}$" --format "{{.Names}}")

    if [ "$RUNNING" != "$CONTAINER_NAME" ]; then
        echo "$(date '+%F %T') 容器未运行，尝试启动 ${CONTAINER_NAME}"
        docker start "$CONTAINER_NAME"
    fi
    ```





