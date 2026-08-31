#!/bin/bash

# ==================================================
# Python 通用启动器（Linux · UTF-8 无 BOM）
# 用法一：把 .py 文件作为参数传入此脚本直接运行
#        （如 ./PYRunner.sh /path/to/script.py）
# 用法二：直接运行，自动探测 Python、按需创建 .venv 并安装依赖，
#         随后扫描并列出同目录下所有 .py 脚本，输入编号选择执行，
#         也可直接输入 / 拖入其它 .py 路径。
# 用法三：PYRunner.sh "path/to/script.py" [参数...]
# ==================================================

SEP="================================================"

# ---------- 脚本所在目录 ----------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

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

# ---------- 结束函数（所有路径统一收尾） ----------
finish() {
    echo ""
    read -p "[结束] 按回车键退出..."
    exit 0
}

fail_finish() {
    echo ""
    read -p "[结束] 按回车键退出..."
    exit 1
}

# ---------- 用法一/三：命令行传参直接运行 ----------
if [ "$#" -ge 1 ]; then
    TARGET="$(sanitize_path "$1")"
    GOTO=run
else
    GOTO=prompt
fi

# ---------- 用法二：显示横幅与脚本选单 ----------
prompt() {
    echo "$SEP"
    echo "      Python 通用启动器"
    echo "      版本 1.0"
    echo "$SEP"
    echo "[适用场景]"
    echo "需要在本目录的独立虚拟环境中运行某个 .py 脚本时使用。"
    echo ""
    echo "[功能说明]"
    echo "自动探测系统 Python，按需创建 .venv 虚拟环境并按 requirements.txt 安装依赖，"
    echo "随后运行选中的 Python 脚本。"
    echo ""
    echo "[操作方式]"
    echo "输入脚本编号选择本目录下的脚本，或直接输入 / 拖入 .py 文件路径；输入 q 或直接回车退出。"
    echo ""
    echo "[执行步骤]"
    echo "1. 选择要运行的 .py 脚本"
    echo "2. 探测系统 Python"
    echo "3. 检查并创建 .venv 虚拟环境"
    echo "4. 检查并安装依赖"
    echo "5. 运行脚本"
    echo "$SEP"
    echo ""

    # ---------- 扫描当前目录下的 .py 脚本 ----------
    SCRIPT_PATHS=()
    SCRIPT_NAMES=()
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        SCRIPT_PATHS+=("$f")
        SCRIPT_NAMES+=("$(basename "$f")")
    done < <(find "$SCRIPT_DIR" -maxdepth 1 -type f -name "*.py" ! -name "PYRunner.sh" ! -name "PYRunner.command" ! -name "PYRunner.cmd" 2>/dev/null | sort)

    SCRIPT_COUNT=${#SCRIPT_PATHS[@]}

    if [ "$SCRIPT_COUNT" -gt 0 ]; then
        echo "[当前目录下的脚本]"
        for ((i = 0; i < SCRIPT_COUNT; i++)); do
            printf "  %2d. %s\n" "$((i + 1))" "${SCRIPT_NAMES[$i]}"
        done
        echo ""
        echo "[操作]"
        echo "  - 输入编号 (1-$SCRIPT_COUNT) 运行脚本"
        echo "  - 或输入 / 拖入 .py 文件路径"
        echo "  - 输入 q 或直接回车退出"
    else
        echo "[提示] 当前目录未发现任何 .py 脚本。"
        echo ""
        echo "[操作]"
        echo "  - 输入 / 拖入 .py 文件路径"
        echo "  - 输入 q 或直接回车退出"
    fi
    echo "$SEP"
    echo ""

    # ---------- 输入循环 ----------
    while true; do
        read -r -p "[输入] 选择脚本或输入路径: " raw_input
        if [ -z "$raw_input" ] || [[ "$raw_input" =~ ^[qQ]$ ]]; then
            echo "[提示] 已取消。"
            finish
        fi

        # 匹配脚本编号
        if [[ "$raw_input" =~ ^[0-9]+$ ]]; then
            idx=$((raw_input - 1))
            if [ "$idx" -ge 0 ] && [ "$idx" -lt "$SCRIPT_COUNT" ]; then
                TARGET="${SCRIPT_PATHS[$idx]}"
                break
            fi
        fi

        # 匹配文件路径
        cleaned="$(sanitize_path "$raw_input")"
        if [ -f "$cleaned" ]; then
            TARGET="$cleaned"
            break
        fi
        # 相对路径尝试
        if [ -f "$SCRIPT_DIR/$cleaned" ]; then
            TARGET="$SCRIPT_DIR/$cleaned"
            break
        fi

        echo ""
        echo "[错误] 无效的选择或文件不存在: $raw_input"
        echo ""
    done
}

# ---------- 用法一/三：直接运行分支 ----------
run() {
    # 规范化目标为绝对路径
    TARGET="$(cd "$(dirname "$TARGET")" && pwd)/$(basename "$TARGET")"
    if [ ! -f "$TARGET" ]; then
        echo "[错误] 文件不存在: $TARGET"
        fail_finish
    fi
    if [[ "$TARGET" != *.py ]]; then
        echo "[错误] 不是 .py 文件: $TARGET"
        fail_finish
    fi

    echo "$SEP"
    echo "      Python 通用启动器"
    echo "      版本 1.0"
    echo "$SEP"
    echo "[运行] 目标脚本: $TARGET"

    # ---------- 步骤 1：探测系统 Python ----------
    PY=""
    if command -v python3 >/dev/null 2>&1; then
        PY="python3"
    elif command -v python >/dev/null 2>&1; then
        PY="python"
    fi
    if [ -z "$PY" ]; then
        echo ""
        echo "[错误] 未检测到 Python，请先安装 Python 或修复 PATH。"
        fail_finish
    fi
    echo "[进度] 使用系统 Python: $PY"

    # ---------- 步骤 2：检查并创建 .venv ----------
    VPY="$SCRIPT_DIR/.venv/bin/python"
    if [ ! -x "$VPY" ]; then
        echo "[进度] 未发现 .venv，正在创建虚拟环境 ..."
        "$PY" -m venv "$SCRIPT_DIR/.venv"
        if [ $? -ne 0 ] || [ ! -x "$VPY" ]; then
            echo "[失败] 虚拟环境创建失败。"
            fail_finish
        fi
    fi
    echo "[完成] 使用虚拟环境 Python: $VPY"

    # ---------- 步骤 3：检查并安装依赖 ----------
    if [ -f "$SCRIPT_DIR/requirements.txt" ]; then
        echo "[进度] 检查并安装依赖 ..."
        "$VPY" -m pip install -r "$SCRIPT_DIR/requirements.txt"
        if [ $? -ne 0 ]; then
            echo "[失败] 依赖安装失败。"
            fail_finish
        fi
        echo "[完成] 依赖就绪。"
    fi

    # ---------- 步骤 4：运行目标脚本（透传剩余参数） ----------
    export PYTHONUTF8=1
    export PYTHONIOENCODING=utf-8
    shift 2>/dev/null || true
    echo ""
    echo "[进度] 开始运行脚本 ..."
    (
        cd "$(dirname "$TARGET")" || exit 1
        "$VPY" -u "$TARGET" "$@"
    )
    rc=$?
    echo ""
    if [ "$rc" -eq 0 ]; then
        echo "[结果] 运行完成（退出码: $rc）。"
    else
        echo "[结果] 运行结束（退出码: $rc）。"
    fi
    finish
}

case "${GOTO:-prompt}" in
    run)    run ;;
    *)      prompt; run ;;
esac
