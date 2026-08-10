#!/bin/bash

echo "========================================="
echo "  Finder 隐藏文件显示控制"
echo "  版本 1.0"
echo "========================================="
echo "[适用场景]"
echo "需要临时查看或隐藏 macOS Finder 中的隐藏文件（如 .DS_Store、隐藏配置目录）时使用。"
echo ""
echo "[功能说明]"
echo "通过修改 Finder 的 AppleShowAllFiles 设置，控制隐藏文件是否显示，并自动重启 Finder 生效。"
echo ""
echo "[操作方式]"
echo "输入选项数字 1 或 2，按回车执行；输入 q 取消。"
echo ""
echo "[执行步骤]"
echo "1. 写入系统设置"
echo "2. 重启 Finder 使设置生效"
echo ""
echo "[注意事项]"
echo "- 执行后所有已打开的 Finder 窗口将被关闭并重新打开。"
echo "- 隐藏文件显示后，请勿随意修改系统关键文件。"
echo "========================================="

# ---------- 菜单选择 ----------
while true; do
    read -p "请输入选项数字 [1 显示隐藏文件 / 2 隐藏隐藏文件 / q 取消] 然后按回车: " choice

    case "$choice" in
        1)
            target="true"
            target_desc="显示隐藏文件"
            ;;
        2)
            target="false"
            target_desc="隐藏隐藏文件"
            ;;
        [qQ])
            echo "[提示] 已取消，未做任何修改。"
            read -p "按回车键退出..."
            exit 0
            ;;
        *)
            echo "[错误] 无效输入，请输入 1、2 或 q。"
            continue
            ;;
    esac

    # ---------- 破坏性操作确认 ----------
    read -p "[提示] 即将${target_desc}，并重启 Finder（已打开的 Finder 窗口将关闭）。确认执行？[y / n] " confirm
    case "$confirm" in
        [yY])
            break
            ;;
        *)
            echo "[提示] 已取消，未做任何修改。"
            read -p "按回车键退出..."
            exit 0
            ;;
    esac
done

# ---------- 执行步骤 ----------
fail_count=0

echo ""
echo "[进度] 步骤 1/2：写入系统设置 ..."
if defaults write com.apple.finder AppleShowAllFiles -boolean "$target" >/dev/null 2>&1; then
    echo "[完成] 系统设置已写入（AppleShowAllFiles = $target）。"
else
    echo "[失败] 写入系统设置失败，可能权限不足。"
    fail_count=$((fail_count + 1))
fi

echo "[进度] 步骤 2/2：重启 Finder 使设置生效 ..."
if killall Finder >/dev/null 2>&1; then
    echo "[完成] Finder 已重启。"
else
    echo "[失败] 重启 Finder 失败。"
    fail_count=$((fail_count + 1))
fi

# ---------- 结果汇总 ----------
echo ""
echo "[结果] 执行完成。"
if [ "$fail_count" -eq 0 ]; then
    echo "  ${target_desc}成功，设置已生效。"
else
    echo "  成功：$((2 - fail_count))/2，失败：${fail_count}/2，请检查后重试。"
fi

read -p "按回车键退出..."
exit 0
