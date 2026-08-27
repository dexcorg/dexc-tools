#!/bin/bash

echo "========================================="
echo "  定时截图工具"
echo "  版本 1.0"
echo "========================================="
echo "[适用场景]"
echo "需要定期自动截取屏幕画面（如监控、录制操作过程、定时记录屏幕状态）时使用。"
echo ""
echo "[功能说明]"
echo "按设定间隔自动截图，文件循环覆盖保存，支持自定义保存目录、截图间隔和保留数量。"
echo ""
echo "[操作方式]"
echo "输入截图保存目录（可拖拽文件夹）、间隔秒数、保留数量，确认后自动执行。"
echo "直接回车使用默认值。"
echo ""
echo "[执行步骤]"
echo "1. 设置截图保存目录"
echo "2. 设置截图间隔（秒）"
echo "3. 设置最大保留数量"
echo "4. 确认参数后开始循环截图"
echo ""
echo "[注意事项]"
echo "- 首次运行需授予屏幕录制权限（系统设置 > 隐私与安全性 > 屏幕录制）。"
echo "- 截图文件按序号循环覆盖，保留最近 N 张。"
echo "- 按 Ctrl+C 可随时停止。"
echo "========================================="

# ---------- 默认值 ----------
DEFAULT_INTERVAL=30
DEFAULT_MAX_COUNT=10

# ---------- 获取脚本所在目录 ----------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEFAULT_SAVE_DIR="$SCRIPT_DIR"

# ---------- 路径规整函数 ----------
sanitize_path() {
    local input="$1"
    input="${input%\"}"
    input="${input#\"}"
    input="${input%\'}"
    input="${input#\'}"
    input=$(printf '%s' "$input" | sed 's/\\ / /g')
    echo "$input"
}

# ---------- 参数变量 ----------
save_dir=""
interval=""
max_count=""

# ---------- 收集参数（参数 1/3：保存目录） ----------
echo ""
echo "[进度] 步骤 1/3：设置截图保存目录 ..."
read -p "[输入] 请输入截图保存目录 [回车使用默认值: $DEFAULT_SAVE_DIR]: " raw_dir

if [ -z "$raw_dir" ]; then
    save_dir="$DEFAULT_SAVE_DIR"
else
    raw_dir=$(sanitize_path "$raw_dir")
    eval raw_dir="$raw_dir"
    if [ -d "$raw_dir" ] || mkdir -p "$raw_dir" 2>/dev/null; then
        save_dir="$(cd "$raw_dir" && pwd)"
    else
        echo "[错误] 目录无效或无法创建，使用默认目录"
        save_dir="$DEFAULT_SAVE_DIR"
    fi
fi
echo "[完成] 保存目录: $save_dir"

# ---------- 收集参数（参数 2/3：截图间隔） ----------
echo ""
echo "[进度] 步骤 2/3：设置截图间隔 ..."
read -p "[输入] 请输入截图间隔（秒）[回车使用默认值: $DEFAULT_INTERVAL]: " raw_interval

if [ -z "$raw_interval" ]; then
    interval=$DEFAULT_INTERVAL
elif [[ "$raw_interval" =~ ^[0-9]+$ ]] && [ "$raw_interval" -gt 0 ]; then
    interval=$raw_interval
else
    echo "[错误] 输入无效，使用默认间隔 $DEFAULT_INTERVAL 秒"
    interval=$DEFAULT_INTERVAL
fi
echo "[完成] 截图间隔: ${interval} 秒"

# ---------- 收集参数（参数 3/3：保留数量） ----------
echo ""
echo "[进度] 步骤 3/3：设置截图保留上限 ..."
read -p "[输入] 请输入截图保留上限（张）[回车使用默认值: $DEFAULT_MAX_COUNT]: " raw_max

if [ -z "$raw_max" ]; then
    max_count=$DEFAULT_MAX_COUNT
elif [[ "$raw_max" =~ ^[0-9]+$ ]] && [ "$raw_max" -gt 0 ]; then
    max_count=$raw_max
else
    echo "[错误] 输入无效，使用默认数量 $DEFAULT_MAX_COUNT"
    max_count=$DEFAULT_MAX_COUNT
fi
echo "[完成] 最大保留: ${max_count} 张"

# ---------- 参数回显确认 ----------
echo ""
echo "[提示] 参数确认："
echo "  保存目录: $save_dir"
echo "  截图间隔: ${interval} 秒"
echo "  最大保留: ${max_count} 张"
echo "  文件名: screenshot_0~$((max_count-1)).png（循环覆盖）"
echo ""
read -p "[输入] 确认开始截图？[y 开始 / q 取消]: " confirm
case "$confirm" in
    [yY])
        ;;
    *)
        echo "[提示] 已取消，未开始截图。"
        read -p "[结束] 按回车键退出..."
        exit 0
        ;;
esac

# ---------- 确保保存目录存在 ----------
mkdir -p "$save_dir"

# ---------- 文件名模板 ----------
file_prefix="screenshot_"
file_ext=".png"

# ---------- 循环索引 ----------
current_index=0

# ---------- 信号处理（Ctrl+C 优雅退出） ----------
trap 'echo ""; echo "[提示] 用户中断，脚本退出。"; read -p "[结束] 按回车键退出..."; exit 0' INT TERM

# ---------- 启动提示 ----------
echo ""
echo "[进度] 开始循环截图 ..."
echo "[提示] 按 Ctrl+C 可随时停止。"
echo ""

# ---------- 主循环 ----------
while true; do
    filename="${save_dir}/${file_prefix}${current_index}${file_ext}"
    screencapture -x "$filename"
    if [ $? -eq 0 ]; then
        echo "[完成] $(date '+%Y-%m-%d %H:%M:%S') 已保存: $filename"
    else
        echo "[失败] $(date '+%Y-%m-%d %H:%M:%S') 截图失败，请检查屏幕录制权限"
    fi
    current_index=$(( (current_index + 1) % max_count ))
    sleep "$interval"
done
