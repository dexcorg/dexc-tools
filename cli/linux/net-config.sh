#!/bin/bash

# ==================================================
# 网卡网络配置工具（Linux · UTF-8 无 BOM）
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
    echo "- 需要 root 权限或 sudo，修改时系统将请求管理员权限。"
    echo "- 网关留空则仅设置本机 IP 与子网掩码，不配置默认路由。"
    echo "$SEP"
}

# ---------- Sudo 前缀 ----------
SUDO=""
if [ "$EUID" -ne 0 ]; then
    SUDO="sudo"
fi

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

# ---------- CIDR 转点分十进制子网掩码 ----------
cidr2mask() {
    local cidr="$1"
    local mask=""
    local full_octets=$((cidr / 8))
    local partial_octet=$((cidr % 8))
    for ((i=0; i<4; i++)); do
        if [ $i -lt $full_octets ]; then
            mask+="255"
        elif [ $i -eq $full_octets ] && [ $partial_octet -gt 0 ]; then
            local val=0
            for ((b=0; b<partial_octet; b++)); do
                val=$((val + (1 << (7 - b))))
            done
            mask+="$val"
        else
            mask+="0"
        fi
        [ $i -lt 3 ] && mask+="."
    done
    echo "$mask"
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
load_adapters() {
    ADAPTER_NAMES=()
    ADAPTER_STATES=()
    ADAPTER_MACS=()

    if [ -d /sys/class/net ]; then
        for devpath in /sys/class/net/*; do
            [ ! -e "$devpath" ] && continue
            local dev
            dev=$(basename "$devpath")
            # 排除环回接口
            [ "$dev" = "lo" ] || [ "$dev" = "lo0" ] && continue

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

            ADAPTER_NAMES+=("$dev")
            ADAPTER_STATES+=("$state")
            ADAPTER_MACS+=("$mac")
        done
    elif command -v ip >/dev/null 2>&1; then
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            local dev
            dev=$(echo "$line" | awk '{print $1}')
            [ "$dev" = "lo" ] || [ "$dev" = "lo0" ] && continue
            local state
            state=$(echo "$line" | awk '{print $2}')
            local mac
            mac=$(echo "$line" | awk '{print $3}')
            ADAPTER_NAMES+=("$dev")
            ADAPTER_STATES+=("$state")
            ADAPTER_MACS+=("${mac:-未获取}")
        done < <(ip -br link show 2>/dev/null)
    elif command -v ifconfig >/dev/null 2>&1; then
        while IFS= read -r dev; do
            [ -z "$dev" ] && continue
            [ "$dev" = "lo" ] || [ "$dev" = "lo0" ] && continue
            local state="UNKNOWN"
            if ifconfig "$dev" 2>/dev/null | grep -q "UP"; then
                state="UP"
            else
                state="DOWN"
            fi
            local mac
            mac=$(ifconfig "$dev" 2>/dev/null | awk '/(ether|HWaddr) / {print $2}')
            ADAPTER_NAMES+=("$dev")
            ADAPTER_STATES+=("$state")
            ADAPTER_MACS+=("${mac:-未获取}")
        done < <(ifconfig -a 2>/dev/null | grep '^[a-zA-Z0-9]' | awk '{print $1}' | tr -d ':')
    fi
}

# ---------- 获取指定网卡详细配置 ----------
get_net_config() {
    local dev="$1"
    local cur_ip=""
    local cur_mask=""
    local cur_gw=""
    local cur_mac="未获取"

    # 查询 MAC 地址
    if [ -f "/sys/class/net/$dev/address" ]; then
        local m
        m=$(cat "/sys/class/net/$dev/address" 2>/dev/null)
        [ -n "$m" ] && [ "$m" != "00:00:00:00:00:00" ] && cur_mac="$m"
    fi

    # 查询 IP 与子网掩码
    if command -v ip >/dev/null 2>&1; then
        local addr_line
        addr_line=$(ip -4 -o addr show dev "$dev" 2>/dev/null | head -n 1)
        if [ -n "$addr_line" ]; then
            local ip_cidr
            ip_cidr=$(echo "$addr_line" | awk '{print $4}')
            cur_ip="${ip_cidr%/*}"
            local prefix="${ip_cidr#*/}"
            if [[ "$prefix" =~ ^[0-9]+$ ]] && [ "$prefix" -ge 0 ] && [ "$prefix" -le 32 ]; then
                cur_mask=$(cidr2mask "$prefix")
            fi
        fi

        # 查询网关
        local gw_line
        gw_line=$(ip route show default dev "$dev" 2>/dev/null | head -n 1)
        if [ -n "$gw_line" ]; then
            cur_gw=$(echo "$gw_line" | awk '{print $3}')
        else
            gw_line=$(ip route show default 2>/dev/null | grep "dev $dev" | head -n 1)
            if [ -n "$gw_line" ]; then
                cur_gw=$(echo "$gw_line" | awk '{print $3}')
            fi
        fi
    elif command -v ifconfig >/dev/null 2>&1; then
        local ifc
        ifc=$(ifconfig "$dev" 2>/dev/null)
        cur_ip=$(echo "$ifc" | awk '/inet / {print $2}' | sed 's/addr://')
        cur_mask=$(echo "$ifc" | awk '/netmask / {print $4}')
        if [ -n "$cur_mask" ] && [[ "$cur_mask" =~ ^0x ]]; then
            local val=$((cur_mask))
            cur_mask=$(printf "%d.%d.%d.%d" $(( (val >> 24) & 255 )) $(( (val >> 16) & 255 )) $(( (val >> 8) & 255 )) $(( val & 255 )))
        fi
        if [ -z "$cur_gw" ] && command -v route >/dev/null 2>&1; then
            cur_gw=$(route -n 2>/dev/null | awk '$1=="0.0.0.0" && $8=="'"$dev"'" {print $2}')
        fi
    fi

    CONFIG_IP="${cur_ip:-未配置 (或 DHCP)}"
    CONFIG_MASK="${cur_mask:-未配置}"
    CONFIG_GW="${cur_gw:-未设置（无网关）}"
    CONFIG_MAC="${cur_mac:-未获取}"
}

# ---------- 应用网络配置 ----------
apply_net_config() {
    local dev="$1"
    local ip="$2"
    local mask="$3"
    local gw="$4"
    local prefix
    prefix=$(mask2cidr "$mask")

    local use_nmcli=0
    if command -v nmcli >/dev/null 2>&1; then
        local nm_dev_status
        nm_dev_status=$(nmcli -t -f DEVICE,STATE dev 2>/dev/null | grep "^${dev}:" | cut -d: -f2)
        if [ -n "$nm_dev_status" ] && [ "$nm_dev_status" != "unmanaged" ]; then
            use_nmcli=1
        fi
    fi

    if [ $use_nmcli -eq 1 ]; then
        local con_name
        con_name=$(nmcli -t -f NAME,DEVICE con show --active 2>/dev/null | grep ":${dev}$" | cut -d: -f1 | head -n 1)
        if [ -z "$con_name" ]; then
            con_name=$(nmcli -t -f NAME,DEVICE con show 2>/dev/null | grep ":${dev}$" | cut -d: -f1 | head -n 1)
        fi
        if [ -z "$con_name" ]; then
            con_name="$dev"
            $SUDO nmcli con add type ethernet ifname "$dev" con-name "$con_name" >/dev/null 2>&1
        fi

        if [ -n "$gw" ]; then
            $SUDO nmcli con mod "$con_name" ipv4.addresses "${ip}/${prefix}" ipv4.gateway "$gw" ipv4.method manual >/dev/null 2>&1
        else
            $SUDO nmcli con mod "$con_name" ipv4.addresses "${ip}/${prefix}" ipv4.gateway "" ipv4.method manual >/dev/null 2>&1
        fi
        $SUDO nmcli con up "$con_name" >/dev/null 2>&1
        return $?
    else
        # 标准 iproute2 回落
        $SUDO ip -4 addr flush dev "$dev" >/dev/null 2>&1
        $SUDO ip addr add "${ip}/${prefix}" dev "$dev" >/dev/null 2>&1
        local res=$?
        $SUDO ip link set dev "$dev" up >/dev/null 2>&1
        if [ -n "$gw" ]; then
            $SUDO ip route replace default via "$gw" dev "$dev" >/dev/null 2>&1
        fi
        return $res
    fi
}

# ===== 主流程 =====
show_banner

# ---------- 权限检查 ----------
if [ "$EUID" -ne 0 ]; then
    echo ""
    echo "[提示] 未以 root 权限运行，修改网卡 IP 时将使用 sudo 请求管理员权限。"
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

adapter_count=${#ADAPTER_NAMES[@]}
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
        printf "  %2d. %-30s (%s)\n" $((i + 1)) "${ADAPTER_NAMES[$i]}" "${ADAPTER_STATES[$i]}"
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

sel_dev="${ADAPTER_NAMES[$sel_index]}"
sel_state="${ADAPTER_STATES[$sel_index]}"

echo "[完成] 已选择网卡: $sel_dev"
echo ""

# ---------- 步骤 2：查看当前配置 ----------
while true; do
    echo "[进度] 步骤 2/4：查看当前配置 ..."
    get_net_config "$sel_dev"

    echo "$SEP"
    echo "     网卡 [ $sel_dev ] 当前配置"
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
        adapter_count=${#ADAPTER_NAMES[@]}
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

        sel_dev="${ADAPTER_NAMES[$sel_index]}"
        sel_state="${ADAPTER_STATES[$sel_index]}"
        echo "[完成] 已选择网卡: $sel_dev"
        echo ""
    fi
done

echo "[提示] 开始修改网卡 [ $sel_dev ] 的 IP 设置。"
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
printf "网卡名称: %s\n" "$sel_dev"
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

if apply_net_config "$sel_dev" "$newIP" "$newMask" "$newGateway"; then
    echo "[完成] 网络配置已成功更新。"
    echo ""
    get_net_config "$sel_dev"
    echo "[结果] 更新后的配置："
    printf "  IP 地址 : %s\n" "$CONFIG_IP"
    printf "  子网掩码: %s\n" "$CONFIG_MASK"
    printf "  默认网关: %s\n" "$CONFIG_GW"
else
    echo "[失败] 配置应用失败，请检查输入参数是否有效。"
fi

echo ""
echo "[结果] 本次配置流程结束。"
read -p "[结束] 按回车键退出..."
exit 0
