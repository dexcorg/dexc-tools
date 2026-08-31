#!/bin/bash

# ==================================================
# 无线网络交互式配置工具（Linux · UTF-8 无 BOM）
# ==================================================

SEP="=================================================="

show_banner() {
    echo "$SEP"
    echo "            无线网络配置工具"
    echo "            版本 1.0"
    echo "$SEP"
    echo "[适用场景]"
    echo "在无 GUI（无桌面环境）的 Linux 系统下，通过无线网卡扫描、连接 WiFi 热点及管理已保存的网络配置。"
    echo ""
    echo "[功能说明]"
    echo "本脚本将执行以下操作："
    echo "  1. 自动检测并列出本机所有物理无线网卡"
    echo "  2. 扫描周边 WiFi 热点列表（SSID、信号强度、安全加密）或手动输入 SSID"
    echo "  3. 收集 WiFi 密码、持久化保存选项与自动连接选项"
    echo "  4. 查看与管理（删除）已保存的 WiFi 网络配置"
    echo ""
    echo "[操作方式]"
    echo "按提示输入编号选择网卡与菜单项，依次输入 WiFi 参数并确认后执行连接。"
    echo "输入 q 可随时返回上一级或取消操作。"
    echo ""
    echo "[执行步骤]"
    echo "1. 检测并选择无线网卡"
    echo "2. 扫描热点或手动指定 SSID 并连接"
    echo "3. 查看与管理已保存的 WiFi 配置（可选）"
    echo ""
    echo "[注意事项]"
    echo "- 连接 WiFi 与管理网络配置需要 root 权限或 sudo，操作时系统将请求管理员权限。"
    echo "- 无线网卡需已开启射频（未处于 RF-Kill 硬件/软件禁用状态）。"
    echo "- 推荐系统已安装并运行 NetworkManager（nmcli）。"
    echo "$SEP"
}

# ---------- Sudo 前缀 ----------
SUDO=""
if [ "$EUID" -ne 0 ]; then
    SUDO="sudo"
fi

# ---------- 工具依赖与射频状态检查 ----------
check_and_enable_wifi_radio() {
    # 尝试解除 rfkill 锁定
    if command -v rfkill >/dev/null 2>&1; then
        local rf_block
        rf_block=$(rfkill list wifi 2>/dev/null | grep -i "blocked: yes")
        if [ -n "$rf_block" ]; then
            echo "[提示] 检测到无线网卡射频处于软/硬禁用状态，正在尝试解除锁定..."
            $SUDO rfkill unblock wifi >/dev/null 2>&1
        fi
    fi

    # 启用 NetworkManager 射频
    if command -v nmcli >/dev/null 2>&1; then
        local nm_radio
        nm_radio=$(nmcli radio wifi 2>/dev/null)
        if [ "$nm_radio" = "disabled" ]; then
            echo "[提示] 正在开启 WiFi 射频开关..."
            $SUDO nmcli radio wifi on >/dev/null 2>&1
        fi
    fi
}

# ---------- 获取无线网卡列表 ----------
load_wireless_adapters() {
    WIFI_ADAPTER_NAMES=()
    WIFI_ADAPTER_STATES=()
    WIFI_ADAPTER_MACS=()

    check_and_enable_wifi_radio

    # 1. 优先通过 /sys/class/net 检测物理无线网卡
    if [ -d /sys/class/net ]; then
        for devpath in /sys/class/net/*; do
            [ ! -e "$devpath" ] && continue
            local dev
            dev=$(basename "$devpath")
            [ "$dev" = "lo" ] || [ "$dev" = "lo0" ] && continue

            local is_wireless=0
            if [ -d "$devpath/wireless" ] || [ -d "$devpath/phy80211" ]; then
                is_wireless=1
            elif command -v iw >/dev/null 2>&1 && iw dev "$dev" info >/dev/null 2>&1; then
                is_wireless=1
            fi

            if [ $is_wireless -eq 1 ]; then
                local state="UNKNOWN"
                if [ -f "$devpath/operstate" ]; then
                    local opstate
                    opstate=$(cat "$devpath/operstate" 2>/dev/null)
                    case "$opstate" in
                        up) state="UP" ;;
                        down) state="DOWN" ;;
                        *) state="${opstate^^}" ;;
                    esac
                fi

                local mac="未获取"
                if [ -f "$devpath/address" ]; then
                    local m
                    m=$(cat "$devpath/address" 2>/dev/null)
                    [ -n "$m" ] && [ "$m" != "00:00:00:00:00:00" ] && mac="$m"
                fi

                WIFI_ADAPTER_NAMES+=("$dev")
                WIFI_ADAPTER_STATES+=("$state")
                WIFI_ADAPTER_MACS+=("$mac")
            fi
        done
    fi

    # 2. 若 sysfs 未检测到，尝试通过 nmcli 检测
    if [ ${#WIFI_ADAPTER_NAMES[@]} -eq 0 ] && command -v nmcli >/dev/null 2>&1; then
        while IFS=: read -r dev devtype devstate _; do
            [ "$devtype" != "wifi" ] && continue
            [ -z "$dev" ] && continue

            local state="UNKNOWN"
            case "$devstate" in
                connected) state="CONNECTED" ;;
                disconnected) state="DISCONNECTED" ;;
                unavailable) state="DOWN" ;;
                *) state="${devstate^^}" ;;
            esac

            local mac="未获取"
            if [ -f "/sys/class/net/$dev/address" ]; then
                mac=$(cat "/sys/class/net/$dev/address" 2>/dev/null)
            fi

            WIFI_ADAPTER_NAMES+=("$dev")
            WIFI_ADAPTER_STATES+=("$state")
            WIFI_ADAPTER_MACS+=("${mac:-未获取}")
        done < <(nmcli -t -f DEVICE,TYPE,STATE dev 2>/dev/null)
    fi
}

# ---------- 获取指定无线网卡当前连接与 IP 信息 ----------
get_wireless_info() {
    local dev="$1"
    CUR_WIFI_SSID="未连接"
    CUR_WIFI_IP="未获取 (或 DHCP)"
    CUR_WIFI_MAC="未获取"
    CUR_WIFI_STATE="DOWN"

    if [ -f "/sys/class/net/$dev/address" ]; then
        local m
        m=$(cat "/sys/class/net/$dev/address" 2>/dev/null)
        [ -n "$m" ] && CUR_WIFI_MAC="$m"
    fi

    if [ -f "/sys/class/net/$dev/operstate" ]; then
        local op
        op=$(cat "/sys/class/net/$dev/operstate" 2>/dev/null)
        [ -n "$op" ] && CUR_WIFI_STATE="${op^^}"
    fi

    if command -v nmcli >/dev/null 2>&1; then
        local active_line
        active_line=$(nmcli -t -f DEVICE,TYPE,STATE,CONNECTION dev 2>/dev/null | grep "^${dev}:wifi:connected:")
        if [ -n "$active_line" ]; then
            CUR_WIFI_SSID=$(echo "$active_line" | cut -d: -f4)
            CUR_WIFI_STATE="CONNECTED"
        fi
    elif command -v iwgetid >/dev/null 2>&1; then
        local ssid
        ssid=$(iwgetid -r "$dev" 2>/dev/null)
        [ -n "$ssid" ] && CUR_WIFI_SSID="$ssid"
    fi

    if command -v ip >/dev/null 2>&1; then
        local ip_line
        ip_line=$(ip -4 -o addr show dev "$dev" 2>/dev/null | head -n 1)
        if [ -n "$ip_line" ]; then
            local ip_cidr
            ip_cidr=$(echo "$ip_line" | awk '{print $4}')
            CUR_WIFI_IP="${ip_cidr}"
        fi
    fi
}

# ---------- 扫描周边 WiFi 热点列表 ----------
scan_wifi_list() {
    local dev="$1"
    SCAN_SSIDS=()
    SCAN_SIGNALS=()
    SCAN_BARS=()
    SCAN_SECS=()
    SCAN_INUSES=()

    echo "[进度] 正在使用网卡 [ $dev ] 扫描周边 WiFi 热点，请稍候 ..."

    if ! command -v nmcli >/dev/null 2>&1; then
        echo "[错误] 未检测到 NetworkManager (nmcli) 工具。"
        echo "[提示] 建议先安装 network-manager：sudo apt-get install network-manager"
        return 1
    fi

    # 触发重新扫描
    $SUDO nmcli dev wifi rescan ifname "$dev" >/dev/null 2>&1
    sleep 1

    # 获取热点列表 (IN-USE,SSID,SIGNAL,BARS,SECURITY)
    local raw_output
    raw_output=$(nmcli -t -f IN-USE,SSID,SIGNAL,BARS,SECURITY dev wifi list ifname "$dev" 2>/dev/null)

    if [ -z "$raw_output" ]; then
        # 部分环境下 ifname 参数可能受限，尝试全局扫描
        raw_output=$(nmcli -t -f IN-USE,SSID,SIGNAL,BARS,SECURITY dev wifi list 2>/dev/null)
    fi

    local seen_ssids=" "

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        
        # nmcli -t 格式说明：星号(*)表示已连接
        local in_use=" "
        if [[ "$line" =~ ^\* ]]; then
            in_use="*"
            line="${line#\*:}"
        else
            line="${line#:}"
        fi

        # 提取字段 (反向提取保证即使 SSID 含特殊字符也能正确解析末尾的 SIGNAL, BARS, SECURITY)
        local sec
        sec=$(echo "$line" | awk -F: '{print $NF}')
        local bars
        bars=$(echo "$line" | awk -F: '{print $(NF-1)}')
        local signal
        signal=$(echo "$line" | awk -F: '{print $(NF-2)}')
        
        # SSID 为前面的所有部分
        local ssid
        ssid=$(echo "$line" | sed "s/:${signal}:${bars}:${sec}$//")
        # 还原 nmcli 转义字符
        ssid=$(echo "$ssid" | sed 's/\\:/:/g')

        # 过滤隐藏 SSID 或空名称
        [ -z "$ssid" ] || [ "$ssid" = "--" ] && continue

        # 去重：若同名 SSID 存在（多频段/多 AP），保留信号最强的一个
        if [[ "$seen_ssids" == *" ${ssid} "* ]]; then
            continue
        fi
        seen_ssids+="${ssid} "

        [ -z "$sec" ] && sec="开放(无加密)"
        [ -z "$bars" ] && bars="----"
        [ -z "$signal" ] && signal="0"

        SCAN_INUSES+=("$in_use")
        SCAN_SSIDS+=("$ssid")
        SCAN_SIGNALS+=("$signal")
        SCAN_BARS+=("$bars")
        SCAN_SECS+=("$sec")
    done <<< "$raw_output"

    return 0
}

# ---------- 打印周边 WiFi 列表表格 ----------
show_wifi_scan_table() {
    local count=${#SCAN_SSIDS[@]}
    echo ""
    echo "$SEP"
    echo "                   周边 WiFi 热点列表"
    echo "$SEP"
    printf "%-6s %-4s %-8s %-12s %-16s %s\n" "编号" "状态" "信号" "强度" "安全加密" "SSID (网络名称)"
    echo "--------------------------------------------------"
    for ((i=0; i<count; i++)); do
        local in_use="${SCAN_INUSES[$i]}"
        local mark=" "
        [ "$in_use" = "*" ] && mark="[已连]"
        printf "  %-4d %-4s %3s%%   %-12s %-16s %s\n" \
            $((i + 1)) \
            "$mark" \
            "${SCAN_SIGNALS[$i]}" \
            "${SCAN_BARS[$i]}" \
            "${SCAN_SECS[$i]}" \
            "${SCAN_SSIDS[$i]}"
    done
    echo "$SEP"
}

# ---------- 执行 WiFi 连接 ----------
do_connect_wifi() {
    local dev="$1"
    local ssid="$2"
    local pw="$3"
    local persist="$4"
    local autoconn="$5"

    echo ""
    echo "[进度] 步骤 4/4：正在连接无线网络 [ $ssid ] ..."

    if ! command -v nmcli >/dev/null 2>&1; then
        echo "[错误] 缺少 nmcli 工具，无法完成自动连接。"
        return 1
    fi

    local connect_success=0
    if [ -n "$pw" ]; then
        if $SUDO nmcli dev wifi connect "$ssid" password "$pw" ifname "$dev" >/dev/null 2>&1; then
            connect_success=1
        fi
    else
        if $SUDO nmcli dev wifi connect "$ssid" ifname "$dev" >/dev/null 2>&1; then
            connect_success=1
        fi
    fi

    if [ $connect_success -eq 1 ]; then
        echo "[完成] 已成功建立与 [ $ssid ] 的无线连接。"

        # 查找当前新生成的连接名称
        local active_con
        active_con=$(nmcli -t -f NAME,DEVICE con show --active 2>/dev/null | grep ":${dev}$" | cut -d: -f1 | head -n 1)
        [ -z "$active_con" ] && active_con="$ssid"

        # 应用自动连接策略
        if [ "$autoconn" -eq 1 ]; then
            $SUDO nmcli con mod "$active_con" connection.autoconnect yes >/dev/null 2>&1
        else
            $SUDO nmcli con mod "$active_con" connection.autoconnect no >/dev/null 2>&1
        fi

        # 处理非持久化（临时连接）：若选择不持久化，连接生效后标记并在退出或必要时清理
        if [ "$persist" -eq 0 ]; then
            echo "[提示] 您选择了不持久化保存配置，该网络已设为禁止自动重连。"
            $SUDO nmcli con mod "$active_con" connection.autoconnect no >/dev/null 2>&1
        fi

        # 获取连接后的 IP 与网关信息
        sleep 2
        get_wireless_info "$dev"

        echo ""
        echo "[结果] 连接状态汇总："
        echo "$SEP"
        printf "  网卡接口  : %s\n" "$dev"
        printf "  已连 SSID : %s\n" "$ssid"
        printf "  分配 IP   : %s\n" "$CUR_WIFI_IP"
        printf "  MAC 地址  : %s\n" "$CUR_WIFI_MAC"
        printf "  持久化保存: %s\n" "$([ "$persist" -eq 1 ] && echo "是" || echo "否 (仅本次连接)")"
        printf "  自动连接  : %s\n" "$([ "$autoconn" -eq 1 ] && echo "是" || echo "否")"
        echo "$SEP"
        return 0
    else
        echo "[失败] 无法连接到 WiFi [ $ssid ]。"
        echo "[提示] 可能原因："
        echo "  1. WiFi 密码错误或安全加密模式不匹配"
        echo "  2. 信号过弱或接入点拒绝连接"
        echo "  3. DHCP 获取 IP 地址超时"
        return 1
    fi
}

# ---------- 收集 WiFi 连接参数流程 ----------
collect_wifi_params_and_connect() {
    local dev="$1"
    local target_ssid="$2"
    local is_manual="$3"

    echo ""
    echo "[进度] 步骤 2/4：确认 WiFi 目标网络 ..."
    if [ "$is_manual" -eq 1 ]; then
        while true; do
            read -p "[输入] 请输入 WiFi SSID (网络名称) (参数 1/4): " manual_ssid
            manual_ssid=$(echo "$manual_ssid" | xargs)
            if [ -n "$manual_ssid" ]; then
                target_ssid="$manual_ssid"
                break
            fi
            echo "[错误] SSID 不能为空，请重新输入。"
        done
    fi
    echo "[完成] 目标网络 SSID: $target_ssid"

    # 参数 2/4: 密码输入
    echo ""
    echo "[进度] 步骤 3/4：收集安全凭据与保存策略 ..."
    local target_pw=""
    while true; do
        read -s -p "[输入] 请输入 WiFi 密码 (参数 2/4，若为开放无密码网络请直接按回车): " raw_pw
        echo ""
        raw_pw=$(echo "$raw_pw" | xargs)
        if [ -z "$raw_pw" ]; then
            read -p "[输入] 密码为空，是否确认为无密码开放网络？[y 是 / n 重新输入密码] [回车默认: y]: " is_open_confirm
            is_open_confirm="${is_open_confirm:-y}"
            if [[ "$is_open_confirm" =~ ^[yY]$ ]]; then
                target_pw=""
                break
            fi
        else
            target_pw="$raw_pw"
            break
        fi
    done
    if [ -n "$target_pw" ]; then
        echo "[完成] WiFi 密码: 已录入（${#target_pw} 位字符）"
    else
        echo "[完成] WiFi 密码: (无密码 / 开放网络)"
    fi

    # 参数 3/4: 持久化保存
    local opt_persist=1
    while true; do
        read -p "[输入] 是否持久化保存此 WiFi 配置（保存 SSID 与密码）？[y 是 / n 否(仅本次连接)] (参数 3/4) [回车默认: y]: " raw_persist
        raw_persist="${raw_persist:-y}"
        if [[ "$raw_persist" =~ ^[yY]$ ]]; then
            opt_persist=1
            break
        elif [[ "$raw_persist" =~ ^[nN]$ ]]; then
            opt_persist=0
            break
        fi
        echo "[错误] 无效输入，请输入 y 或 n。"
    done
    echo "[完成] 持久化保存: $([ "$opt_persist" -eq 1 ] && echo "是" || echo "否")"

    # 参数 4/4: 下次是否自动连接
    local opt_autoconn=1
    if [ "$opt_persist" -eq 1 ]; then
        while true; do
            read -p "[输入] 下次开机或网卡启用时是否自动连接此 WiFi？[y 是 / n 否] (参数 4/4) [回车默认: y]: " raw_autoconn
            raw_autoconn="${raw_autoconn:-y}"
            if [[ "$raw_autoconn" =~ ^[yY]$ ]]; then
                opt_autoconn=1
                break
            elif [[ "$raw_autoconn" =~ ^[nN]$ ]]; then
                opt_autoconn=0
                break
            fi
            echo "[错误] 无效输入，请输入 y 或 n。"
        done
    else
        opt_autoconn=0
    fi
    echo "[完成] 自动连接: $([ "$opt_autoconn" -eq 1 ] && echo "是" || echo "否")"

    # 参数回显与确认
    echo ""
    echo "[提示] 即将执行的 WiFi 配置如下："
    echo "$SEP"
    printf "无线网卡    : %s\n" "$dev"
    printf "目标 SSID   : %s\n" "$target_ssid"
    if [ -n "$target_pw" ]; then
        printf "WiFi 密码   : %s (共 %d 位)\n" "********" "${#target_pw}"
    else
        printf "WiFi 密码   : (开放无密码网络)\n"
    fi
    printf "持久化保存  : %s\n" "$([ "$opt_persist" -eq 1 ] && echo "是" || echo "否 (仅本次连接)")"
    printf "下次自动连接: %s\n" "$([ "$opt_autoconn" -eq 1 ] && echo "是" || echo "否")"
    echo "$SEP"

    while true; do
        read -p "[输入] 确认开始连接？[y 连接 / q 取消] " confirm_con
        if [[ "$confirm_con" =~ ^[yY]$ ]]; then
            break
        fi
        if [[ "$confirm_con" =~ ^[qQ]$ ]]; then
            echo "[提示] 操作已取消，未发起连接。"
            return 0
        fi
        echo "[错误] 无效输入，请输入 y 或 q。"
    done

    # 执行连接
    do_connect_wifi "$dev" "$target_ssid" "$target_pw" "$opt_persist" "$opt_autoconn"
}

# ---------- 扫描周边并选择连接 ----------
menu_scan_and_connect() {
    local dev="$1"
    while true; do
        if ! scan_wifi_list "$dev"; then
            read -p "[输入] 扫描遇到问题，按回车返回主菜单..." _
            return 1
        fi

        local count=${#SCAN_SSIDS[@]}
        if [ "$count" -eq 0 ]; then
            echo "[提示] 未扫描到周边的有效 WiFi 热点。"
            echo ""
            echo "选项："
            echo "  r. 重新扫描"
            echo "  m. 手动输入 SSID 连接 (例如隐藏网络)"
            echo "  q. 返回主菜单"
            read -p "[输入] 请选择操作 [r 重新扫描 / m 手动输入 / q 返回]: " no_res_act
            case "$no_res_act" in
                [rR]) continue ;;
                [mM]) collect_wifi_params_and_connect "$dev" "" 1; return 0 ;;
                *) return 0 ;;
            esac
        fi

        show_wifi_scan_table

        echo ""
        echo "[提示] 可输入热点编号进行连接，或输入 r 重新扫描，m 手动输入 SSID，q 返回。"
        while true; do
            read -p "[输入] 请选择 WiFi 编号 [1 - ${count} / r 重扫 / m 手动 / q 返回]: " sel_act
            if [[ "$sel_act" =~ ^[qQ]$ ]]; then
                return 0
            fi
            if [[ "$sel_act" =~ ^[rR]$ ]]; then
                break
            fi
            if [[ "$sel_act" =~ ^[mM]$ ]]; then
                collect_wifi_params_and_connect "$dev" "" 1
                return 0
            fi
            if [[ "$sel_act" =~ ^[0-9]+$ ]] && [ "$sel_act" -ge 1 ] && [ "$sel_act" -le "$count" ]; then
                local chosen_idx=$((sel_act - 1))
                local chosen_ssid="${SCAN_SSIDS[$chosen_idx]}"
                collect_wifi_params_and_connect "$dev" "$chosen_ssid" 0
                return 0
            fi
            echo "[错误] 无效输入，请输入 1 - ${count}，r，m 或 q。"
        done
    done
}

# ---------- 读取已保存的 WiFi 配置列表 ----------
load_saved_wifi_connections() {
    SAVED_CON_NAMES=()
    SAVED_CON_UUIDS=()
    SAVED_CON_AUTOCONNS=()
    SAVED_CON_ACTIVES=()

    if ! command -v nmcli >/dev/null 2>&1; then
        return 1
    fi

    while IFS=: read -r name uuid ctype autoconn dev; do
        [ "$ctype" != "802-11-wireless" ] && continue
        [ -z "$name" ] && continue

        local is_active="否"
        if [ -n "$dev" ] && [ "$dev" != "--" ]; then
            is_active="已连接 ($dev)"
        fi

        local auto_str="否"
        [ "$autoconn" = "yes" ] && auto_str="是"

        SAVED_CON_NAMES+=("$name")
        SAVED_CON_UUIDS+=("$uuid")
        SAVED_CON_AUTOCONNS+=("$auto_str")
        SAVED_CON_ACTIVES+=("$is_active")
    done < <(nmcli -t -f NAME,UUID,TYPE,AUTOCONNECT,DEVICE con show 2>/dev/null)
}

# ---------- 管理已保存的 WiFi 配置（查看与删除） ----------
menu_manage_saved_wifi() {
    while true; do
        echo ""
        echo "[进度] 正在查询本机已保存的 WiFi 配置列表 ..."
        load_saved_wifi_connections

        local count=${#SAVED_CON_NAMES[@]}
        if [ "$count" -eq 0 ]; then
            echo "[提示] 当前系统未保存任何 WiFi 网络配置。"
            echo ""
            read -p "[输入] 按回车键返回主菜单..." _
            return 0
        fi

        echo ""
        echo "$SEP"
        echo "               已保存的 WiFi 配置列表与管理"
        echo "$SEP"
        printf "%-6s %-24s %-12s %s\n" "编号" "WiFi 名称 (SSID)" "自动连接" "当前状态"
        echo "--------------------------------------------------"
        for ((i=0; i<count; i++)); do
            printf "  %-4d %-24s %-12s %s\n" \
                $((i + 1)) \
                "${SAVED_CON_NAMES[$i]}" \
                "${SAVED_CON_AUTOCONNS[$i]}" \
                "${SAVED_CON_ACTIVES[$i]}"
        done
        echo "$SEP"
        echo "[提示] 仅查看请直接按回车或输入 q 返回；若需删除请输入对应编号。"

        local raw_act=""
        read -p "[输入] 请输入要删除的 WiFi 编号 [1 - ${count} / q 返回 (直接回车也可返回)]: " raw_act
        raw_act=$(echo "$raw_act" | xargs)

        if [ -z "$raw_act" ] || [[ "$raw_act" =~ ^[qQ]$ ]]; then
            return 0
        fi

        if ! [[ "$raw_act" =~ ^[0-9]+$ ]] || [ "$raw_act" -lt 1 ] || [ "$raw_act" -gt "$count" ]; then
            echo "[错误] 无效输入，请输入 1 - ${count} 或 q。"
            continue
        fi

        local del_idx=$((raw_act - 1))
        local del_name="${SAVED_CON_NAMES[$del_idx]}"
        local del_uuid="${SAVED_CON_UUIDS[$del_idx]}"

        echo ""
        echo "[提示] 破坏性操作警告："
        echo "  即将从系统中永久移除 WiFi 配置文件 [ $del_name ]。"
        echo "  删除后，系统将清除该网络的密码和自动连接设定。"

        while true; do
            read -p "[输入] 确认彻底删除 [ $del_name ]？[y 确认删除 / q 取消返回]: " confirm_del
            if [[ "$confirm_del" =~ ^[qQ]$ ]]; then
                echo "[提示] 已取消删除操作。"
                break
            fi
            if [[ "$confirm_del" =~ ^[yY]$ ]]; then
                echo "[进度] 正在删除配置 [ $del_name ] ..."
                if $SUDO nmcli con delete "$del_uuid" >/dev/null 2>&1; then
                    echo "[完成] 已成功删除 WiFi 配置: $del_name"
                else
                    echo "[失败] 删除 WiFi 配置失败，请检查管理员权限。"
                fi
                break
            fi
            echo "[错误] 无效输入，请输入 y 或 q。"
        done

        read -p "[输入] 是否继续管理其它已保存的 WiFi？[y 继续 / n 返回主菜单] [回车默认: n]: " continue_del
        continue_del="${continue_del:-n}"
        if ! [[ "$continue_del" =~ ^[yY]$ ]]; then
            return 0
        fi
    done
}

# ===== 主程序流程 =====
show_banner

# ---------- 权限检查 ----------
if [ "$EUID" -ne 0 ]; then
    echo ""
    echo "[提示] 未以 root 权限运行，连接 WiFi 与管理网络配置时将使用 sudo 请求管理员权限。"
    read -p "[输入] 是否继续？[y 继续 / n 退出] " ok
    case "$ok" in
        [yY])
            ;;
        *)
            echo "[提示] 操作已取消。"
            read -p "[结束] 按回车键退出..."
            exit 0
            ;;
    esac
    echo ""
fi

# ---------- 主循环：网卡选择与功能菜单 ----------
while true; do
    echo "[进度] 步骤 1/4：检测物理无线网卡设备 ..."
    load_wireless_adapters

    adapter_count=${#WIFI_ADAPTER_NAMES[@]}
    if [ "$adapter_count" -eq 0 ]; then
        echo ""
        echo "[错误] 未检测到任何物理无线网卡设备。"
        echo "[提示] 排查建议："
        echo "  1. 检查无线网卡是否已插紧，USB 无线网卡是否已被系统识别（lsusb/lspci）"
        echo "  2. 检查无线网卡驱动是否正确安装加载"
        echo "  3. 确认未被硬件开关物理关闭"
        echo ""
        read -p "[结束] 按回车键退出..."
        exit 0
    fi

    # 展示无线网卡列表
    show_adapter_menu() {
        echo ""
        echo "可用无线网卡列表："
        echo "$SEP"
        for ((i=0; i<adapter_count; i++)); do
            printf "  %2d. %-20s (状态: %-8s | MAC: %s)\n" \
                $((i + 1)) \
                "${WIFI_ADAPTER_NAMES[$i]}" \
                "${WIFI_ADAPTER_STATES[$i]}" \
                "${WIFI_ADAPTER_MACS[$i]}"
        done
        echo "$SEP"
    }

    sel_adapter_index=0
    if [ "$adapter_count" -gt 1 ]; then
        show_adapter_menu
        while true; do
            read -p "[输入] 请选择要操作的无线网卡编号 [1 - ${adapter_count} / q 退出] 然后按回车: " raw_nic
            if [[ "$raw_nic" =~ ^[qQ]$ ]]; then
                echo "[提示] 操作已取消。"
                read -p "[结束] 按回车键退出..."
                exit 0
            fi
            if [[ "$raw_nic" =~ ^[0-9]+$ ]] && [ "$raw_nic" -ge 1 ] && [ "$raw_nic" -le "$adapter_count" ]; then
                sel_adapter_index=$((raw_nic - 1))
                break
            fi
            echo "[错误] 无效输入，请输入 1 - ${adapter_count} 或 q。"
        done
    fi

    CURRENT_DEV="${WIFI_ADAPTER_NAMES[$sel_adapter_index]}"
    echo "[完成] 已选择无线网卡: $CURRENT_DEV"

    # 网卡级功能主菜单
    while true; do
        get_wireless_info "$CURRENT_DEV"
        echo ""
        echo "$SEP"
        echo "  无线网络管理中心 ｜ 当前网卡: [ $CURRENT_DEV ]"
        echo "$SEP"
        printf "  当前状态 : %s\n" "$CUR_WIFI_STATE"
        printf "  当前 WiFi: %s\n" "$CUR_WIFI_SSID"
        printf "  当前 IP  : %s\n" "$CUR_WIFI_IP"
        printf "  MAC 地址 : %s\n" "$CUR_WIFI_MAC"
        echo "--------------------------------------------------"
        echo "  1. 扫描周边 WiFi 并连接"
        echo "  2. 手动输入 SSID 连接 (支持隐藏 WiFi)"
        echo "  3. 管理已保存的 WiFi 配置 (查看与删除)"
        echo "  4. 重新检测 / 切换无线网卡"
        echo "  q. 退出工具"
        echo "$SEP"

        read -p "[输入] 请输入操作编号 [1 - 4 / q 退出] 然后按回车: " menu_choice
        case "$menu_choice" in
            1)
                menu_scan_and_connect "$CURRENT_DEV"
                ;;
            2)
                collect_wifi_params_and_connect "$CURRENT_DEV" "" 1
                ;;
            3)
                menu_manage_saved_wifi
                ;;
            4)
                echo "[提示] 重新选择网卡..."
                break
                ;;
            [qQ])
                echo ""
                echo "[结果] 退出无线网络配置工具。"
                read -p "[结束] 按回车键退出..."
                exit 0
                ;;
            *)
                echo "[错误] 无效输入，请输入 1 - 4 或 q。"
                ;;
        esac
    done
done
