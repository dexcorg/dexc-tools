#!/bin/bash

# ==================================================
# 网卡网络配置工具（macOS · UTF-8 无 BOM）
# ==================================================

SEP="=================================================="

show_banner() {
    echo "$SEP"
    echo "            网卡网络配置工具"
    echo "            版本 1.0"
    echo "$SEP"
    echo "[适用场景]"
    echo "需要为指定网卡设置静态 IP 地址、子网掩码和默认网关，或查看网卡当前配置时使用。"
    echo ""
    echo "[功能说明]"
    echo "本脚本将执行以下操作："
    echo "  1. 列出本机所有网卡及其连接状态"
    echo "  2. 显示所选网卡的当前 IP、子网掩码、默认网关与 MAC 地址"
    echo "  3. 收集新的 IP、子网掩码、默认网关（网关可留空）"
    echo "  4. 确认后应用静态 IP 配置"
    echo ""
    echo "[操作方式]"
    echo "按提示输入网卡编号选择要操作的网卡，再依次输入新 IP、子网掩码、默认网关，"
    echo "确认无误后输入 y 执行，输入 q 可随时取消。"
    echo ""
    echo "[执行步骤]"
    echo "1. 选择要配置的网卡"
    echo "2. 查看当前配置"
    echo "3. 输入新的 IP、子网掩码、默认网关"
    echo "4. 确认并应用配置"
    echo ""
    echo "[注意事项]"
    echo "- 修改网卡 IP 可能导致本机网络短暂中断，请在确认前保存未完成的工作。"
    echo "- 需要管理员权限，修改时系统将请求管理员密码（sudo）。"
    echo "- 网关留空则仅设置本机 IP 与子网掩码，不配置默认路由。"
    echo "$SEP"
}

# ---------- IPv4 格式校验 ----------
validate_ipv4() {
    local ip="$1"
    local IFS=.
    local octets=($ip)
    if [ ${#octets[@]} -ne 4 ]; then
        return 1
    fi
    for octet in "${octets[@]}"; do
        if ! [[ "$octet" =~ ^[0-9]+$ ]] || [ "$octet" -lt 0 ] || [ "$octet" -gt 255 ]; then
            return 1
        fi
        if [[ "$octet" =~ ^0[0-9]+$ ]]; then
            return 1
        fi
    done
    return 0
}

# ---------- 子网掩码转 CIDR ----------
mask2cidr() {
    local mask="$1"
    local cidr=0
    local IFS=.
    local octets=($mask)
    [ ${#octets[@]} -ne 4 ] && return 1
    local end_of_ones=0
    for octet in "${octets[@]}"; do
        if ! [[ "$octet" =~ ^[0-9]+$ ]]; then
            return 1
        fi
        case "$octet" in
            255) [ $end_of_ones -eq 1 ] && return 1; ((cidr += 8)) ;;
            254) [ $end_of_ones -eq 1 ] && return 1; end_of_ones=1; ((cidr += 7)) ;;
            252) [ $end_of_ones -eq 1 ] && return 1; end_of_ones=1; ((cidr += 6)) ;;
            248) [ $end_of_ones -eq 1 ] && return 1; end_of_ones=1; ((cidr += 5)) ;;
            240) [ $end_of_ones -eq 1 ] && return 1; end_of_ones=1; ((cidr += 4)) ;;
            224) [ $end_of_ones -eq 1 ] && return 1; end_of_ones=1; ((cidr += 3)) ;;
            192) [ $end_of_ones -eq 1 ] && return 1; end_of_ones=1; ((cidr += 2)) ;;
            128) [ $end_of_ones -eq 1 ] && return 1; end_of_ones=1; ((cidr += 1)) ;;
            0)   end_of_ones=1; ((cidr += 0)) ;;
            *) return 1 ;;
        esac
    done
    echo "$cidr"
}

# ---------- 子网掩码校验 ----------
validate_subnet_mask() {
    local mask="$1"
    if ! validate_ipv4 "$mask"; then
        return 1
    fi
    mask2cidr "$mask" >/dev/null 2>&1 || return 1
    return 0
}

# ---------- 获取网卡列表 ----------
# 数组元素格式: 服务名称|设备名|连接状态|MAC地址
load_adapters() {
    ADAPTER_SERVICES=()
    ADAPTER_DEVICES=()
    ADAPTER_STATES=()
    ADAPTER_MACS=()

    local ports_info
    ports_info=$(networksetup -listallhardwareports 2>/dev/null)

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        [[ "$line" == *"denotes that a network service is disabled"* ]] && continue

        local is_disabled=0
        local service="$line"
        if [[ "$service" =~ ^\* ]]; then
            is_disabled=1
            service="${service#\*}"
        fi

        local block
        block=$(echo "$ports_info" | awk -v RS= -v port="$service" '$0 ~ "Hardware Port: " port {print}')
        local dev
        dev=$(echo "$block" | awk -F": " '/Device:/ {print $2}')
        local mac
        mac=$(echo "$block" | awk -F": " '/Ethernet Address:/ {print $2}')

        local state="未连接"
        if [ -n "$dev" ]; then
            if ifconfig "$dev" 2>/dev/null | grep -q "status: active"; then
                state="已连接"
            elif ifconfig "$dev" 2>/dev/null | grep -q "<UP,"; then
                if ifconfig "$dev" 2>/dev/null | grep -q "inet "; then
                    state="已连接"
                fi
            fi
        fi
        if [ $is_disabled -eq 1 ]; then
            state="已停用"
        fi

        ADAPTER_SERVICES+=("$service")
        ADAPTER_DEVICES+=("$dev")
        ADAPTER_STATES+=("$state")
        ADAPTER_MACS+=("$mac")
    done < <(networksetup -listallnetworkservices 2>/dev/null)
}

# ---------- 获取指定网卡详细配置 ----------
get_net_config() {
    local service="$1"
    local dev="$2"
    local cur_ip=""
    local cur_mask=""
    local cur_gw=""
    local cur_mac=""

    local info
    info=$(networksetup -getinfo "$service" 2>/dev/null)

    cur_ip=$(echo "$info" | awk -F": " '/^IP address:/ {print $2}')
    [ "$cur_ip" = "none" ] && cur_ip=""

    cur_mask=$(echo "$info" | awk -F": " '/^Subnet mask:/ {print $2}')
    [ "$cur_mask" = "none" ] && cur_mask=""

    cur_gw=$(echo "$info" | awk -F": " '/^Router:/ {print $2}')
    [ "$cur_gw" = "none" ] && cur_gw=""

    cur_mac=$(echo "$info" | awk -F": " '/(Ethernet Address|Wi-Fi ID):/ {print $2}')

    # 回落至 ifconfig
    if [ -n "$dev" ]; then
        local ifc
        ifc=$(ifconfig "$dev" 2>/dev/null)
        if [ -z "$cur_ip" ]; then
            cur_ip=$(echo "$ifc" | awk '/inet / && !/inet6/ {print $2}')
        fi
        if [ -z "$cur_mask" ]; then
            local hexmask
            hexmask=$(echo "$ifc" | awk '/inet / && !/inet6/ {print $4}')
            if [ -n "$hexmask" ] && [[ "$hexmask" =~ ^0x ]]; then
                local val=$((hexmask))
                cur_mask=$(printf "%d.%d.%d.%d" $(( (val >> 24) & 255 )) $(( (val >> 16) & 255 )) $(( (val >> 8) & 255 )) $(( val & 255 )))
            fi
        fi
        if [ -z "$cur_mac" ]; then
            cur_mac=$(echo "$ifc" | awk '/ether / {print $2}')
        fi
    fi

    CONFIG_IP="${cur_ip:-未配置 (或 DHCP)}"
    CONFIG_MASK="${cur_mask:-未配置}"
    CONFIG_GW="${cur_gw:-未设置（无网关）}"
    CONFIG_MAC="${cur_mac:-未获取}"
}

# ===== 主流程 =====
show_banner

# ---------- 权限检查 ----------
if [ "$EUID" -ne 0 ]; then
    echo ""
    echo "[提示] 未以 root 权限运行，修改网卡 IP 时将请求管理员权限（sudo）。"
    read -p "[输入] 是否仍要继续？[y 继续 / n 取消] " ok
    case "$ok" in
        [yY])
            ;;
        *)
            echo "[提示] 已取消，未做任何修改。"
            read -p "[结束] 按回车键退出..."
            exit 0
            ;;
    esac
    echo ""
fi

# ---------- 步骤 1：选择网卡 ----------
echo ""
echo "[进度] 步骤 1/4：选择要配置的网卡 ..."
load_adapters

adapter_count=${#ADAPTER_SERVICES[@]}
if [ "$adapter_count" -eq 0 ]; then
    echo ""
    echo "[错误] 未找到任何网络适配器。"
    echo ""
    read -p "[结束] 按回车键退出..."
    exit 0
fi

show_adapter_menu() {
    echo ""
    echo "可用网络适配器列表："
    echo "$SEP"
    for ((i=0; i<adapter_count; i++)); do
        local display_name="${ADAPTER_SERVICES[$i]}"
        if [ -n "${ADAPTER_DEVICES[$i]}" ]; then
            display_name="${display_name} (${ADAPTER_DEVICES[$i]})"
        fi
        printf "  %2d. %-30s (%s)\n" $((i + 1)) "$display_name" "${ADAPTER_STATES[$i]}"
    done
    echo "$SEP"
}

show_adapter_menu

sel_index=-1
while true; do
    read -p "[输入] 请输入要查看/配置的网卡编号 [1 - ${adapter_count} / q 取消] 然后按回车: " raw_input
    if [[ "$raw_input" =~ ^[qQ]$ ]]; then
        echo "[提示] 已取消，未做任何修改。"
        read -p "[结束] 按回车键退出..."
        exit 0
    fi
    if [[ "$raw_input" =~ ^[0-9]+$ ]] && [ "$raw_input" -ge 1 ] && [ "$raw_input" -le "$adapter_count" ]; then
        sel_index=$((raw_input - 1))
        break
    fi
    echo "[错误] 无效输入，请输入 1 - ${adapter_count} 或 q。"
done

sel_service="${ADAPTER_SERVICES[$sel_index]}"
sel_dev="${ADAPTER_DEVICES[$sel_index]}"
sel_state="${ADAPTER_STATES[$sel_index]}"

echo "[完成] 已选择网卡: $sel_service"
echo ""

# ---------- 步骤 2：查看当前配置 ----------
while true; do
    echo "[进度] 步骤 2/4：查看当前配置 ..."
    get_net_config "$sel_service" "$sel_dev"

    echo "$SEP"
    echo "     网卡 [ $sel_service ] 当前配置"
    echo "$SEP"
    printf "连接状态      : %s\n" "$sel_state"
    printf "IP 地址       : %s\n" "$CONFIG_IP"
    printf "子网掩码      : %s\n" "$CONFIG_MASK"
    printf "默认网关      : %s\n" "$CONFIG_GW"
    printf "MAC 地址      : %s\n" "$CONFIG_MAC"
    echo "$SEP"
    echo "[完成] 当前配置查看完毕。"
    echo ""

    # 是否修改
    read -p "[输入] 是否要修改此网卡的 IP 地址？[y 修改 / n 返回重新选择 / q 退出]: " yn
    if [[ "$yn" =~ ^[qQ]$ ]]; then
        echo "[提示] 已取消，未做任何修改。"
        read -p "[结束] 按回车键退出..."
        exit 0
    fi
    if [[ "$yn" =~ ^[yY]$ ]]; then
        break
    fi
    if [[ "$yn" =~ ^[nN]$ ]]; then
        echo "[提示] 返回重新选择网卡。"
        echo ""
        echo "[进度] 重新选择网卡 ..."
        load_adapters
        adapter_count=${#ADAPTER_SERVICES[@]}
        if [ "$adapter_count" -eq 0 ]; then
            echo "[错误] 未找到任何网络适配器。"
            read -p "[结束] 按回车键退出..."
            exit 0
        fi

        show_adapter_menu

        while true; do
            read -p "[输入] 请输入要查看/配置的网卡编号 [1 - ${adapter_count} / q 取消] 然后按回车: " raw_input
            if [[ "$raw_input" =~ ^[qQ]$ ]]; then
                echo "[提示] 已取消，未做任何修改。"
                read -p "[结束] 按回车键退出..."
                exit 0
            fi
            if [[ "$raw_input" =~ ^[0-9]+$ ]] && [ "$raw_input" -ge 1 ] && [ "$raw_input" -le "$adapter_count" ]; then
                sel_index=$((raw_input - 1))
                break
            fi
            echo "[错误] 无效输入，请输入 1 - ${adapter_count} 或 q。"
        done

        sel_service="${ADAPTER_SERVICES[$sel_index]}"
        sel_dev="${ADAPTER_DEVICES[$sel_index]}"
        sel_state="${ADAPTER_STATES[$sel_index]}"
        echo "[完成] 已选择网卡: $sel_service"
        echo ""
    fi
done

echo "[提示] 开始修改网卡 [ $sel_service ] 的 IP 设置。"
echo ""

# ---------- 步骤 3：收集参数（3 个参数） ----------
echo "[进度] 步骤 3/4：输入新的网络参数 ..."

newIP=""
while true; do
    read -p "[输入] 请输入新的 IP 地址 (参数 1/3，例如: 192.168.10.100): " raw_ip
    raw_ip=$(echo "$raw_ip" | xargs)
    if validate_ipv4 "$raw_ip"; then
        newIP="$raw_ip"
        break
    fi
    echo "[错误] 输入无效，请输入正确的 IP 地址格式（例如 192.168.10.100）。"
done
echo "[完成] IP 地址: $newIP"

newMask=""
while true; do
    read -p "[输入] 请输入新的子网掩码 (参数 2/3，例如: 255.255.255.0): " raw_mask
    raw_mask=$(echo "$raw_mask" | xargs)
    if validate_subnet_mask "$raw_mask"; then
        newMask="$raw_mask"
        break
    fi
    echo "[错误] 输入无效，请输入正确的子网掩码格式（例如 255.255.255.0）。"
done
echo "[完成] 子网掩码: $newMask"

newGateway=""
read -p "[输入] 请输入新的默认网关 (参数 3/3，直接回车可留空): " raw_gw
raw_gw=$(echo "$raw_gw" | xargs)
if [ -n "$raw_gw" ]; then
    if validate_ipv4 "$raw_gw"; then
        newGateway="$raw_gw"
    else
        echo "[错误] 网关格式无效，将按留空处理（不配置默认路由）。"
        newGateway=""
    fi
fi
if [ -n "$newGateway" ]; then
    echo "[完成] 默认网关: $newGateway"
else
    echo "[完成] 默认网关: (未设置)"
fi

# ---------- 参数回显确认 ----------
echo ""
echo "[提示] 配置确认："
echo "$SEP"
printf "网卡名称: %s\n" "$sel_service"
printf "新 IP   : %s\n" "$newIP"
printf "子网掩码: %s\n" "$newMask"
if [ -n "$newGateway" ]; then
    printf "默认网关: %s\n" "$newGateway"
else
    echo "默认网关: (未设置)"
fi
echo "$SEP"
echo "[提示] 执行后将修改所选网卡的 IP 配置，网络可能短暂中断。"

# ---------- 步骤 4：确认并应用 ----------
while true; do
    read -p "[输入] 确认应用此配置？[y 应用 / q 取消] " confirm
    if [[ "$confirm" =~ ^[yY]$ ]]; then
        break
    fi
    if [[ "$confirm" =~ ^[qQ]$ ]]; then
        echo "[提示] 操作已取消，未做任何修改。"
        read -p "[结束] 按回车键退出..."
        exit 0
    fi
    echo "[错误] 无效输入，请输入 y 或 q。"
done

echo ""
echo "[进度] 步骤 4/4：应用新的网卡配置 ..."

if [ "$EUID" -eq 0 ]; then
    networksetup -setmanual "$sel_service" "$newIP" "$newMask" "$newGateway" >/dev/null 2>&1
    cmd_status=$?
else
    sudo networksetup -setmanual "$sel_service" "$newIP" "$newMask" "$newGateway" >/dev/null 2>&1
    cmd_status=$?
fi

if [ $cmd_status -eq 0 ]; then
    echo "[完成] 网络配置已成功更新。"
    echo ""
    get_net_config "$sel_service" "$sel_dev"
    echo "[结果] 更新后的配置："
    printf "  IP 地址 : %s\n" "$CONFIG_IP"
    printf "  子网掩码: %s\n" "$CONFIG_MASK"
    printf "  默认网关: %s\n" "$CONFIG_GW"
else
    echo "[失败] 配置应用失败，请检查输入参数是否有效（退出码: $cmd_status）。"
fi

echo ""
echo "[结果] 本次配置流程结束。"
read -p "[结束] 按回车键退出..."
exit 0
