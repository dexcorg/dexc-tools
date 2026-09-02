#!/bin/bash

# ==================================================
# 设备协议检测工具（Linux · UTF-8 无 BOM）
# 为 cli/windows/device-protocol-scan.ps1 的 Linux Bash 移植版
# ==================================================

SEP="=================================================="

# ---------- 全局变量 ----------
SUBNET=""
PROTO_ARG=""
PORTS_ARG=""
IFACE_ARG=""
TIMEOUT_MS=1500
PING_TIMEOUT_MS=500
OUTFILE=""

EXTRA_PORTS=()
SELECTED_IDX=-1
SELECTED_PROTO=""
HOSTS=()
ALIVE=()
SCAN_PORTS=()
OPEN_PAIRS=()
RESULTS=()

# 网卡候选（并行数组）
NIC_NAMES=()
NIC_IPS=()
NIC_PREFIXES=()
NIC_STATES=()
NIC_SEL_NAME=""
NIC_SEL_IP=""
NIC_SEL_PREFIX=""

INTERACTIVE=1
[ -t 0 ] || INTERACTIVE=0
[ -t 1 ] || INTERACTIVE=0

# ---------- 工具检测 ----------
TMO=""
if command -v timeout >/dev/null 2>&1; then
    TMO="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
    TMO="gtimeout"
fi

OPENSSL_MISSING=1
command -v openssl >/dev/null 2>&1 && OPENSSL_MISSING=0

HAVE_IPROUTE=1
command -v ip >/dev/null 2>&1 || HAVE_IPROUTE=0
HAVE_IFCONFIG=1
command -v ifconfig >/dev/null 2>&1 || HAVE_IFCONFIG=0

# ---------- 协议注册表（并行数组，兼容 bash 3+） ----------
PROTO_COUNT=12
PROTO_NAMES=(HTTP HTTPS SSH FTP SMTP RTSP Telnet RDP SMB SIP MQTT Redis)
PROTO_PORTS=(80 443 22 21 25 "554 8554" 23 3389 445 5060 1883 6379)

# 二进制报文定义（与 ps1 / Python 版字节一致）
RDP_REQ='\x03\x00\x00\x13\x0e\xe0\x00\x00\x00\x01\x00\x08\x00\x03\x00\x00\x00\x00\x00'
MQTT_REQ='\x10\x0c\x00\x04MQTT\x04\x02\x00\x3c\x00\x00'
SMB_REQ='\x00\x00\x00\x68\xfe\x53\x4d\x42\x40\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x24\x00\x02\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x02\x10\x02'

# ==================================================
# IP / 网段工具
# ==================================================

ip2uint() {
    local IFS=. a b c d
    read -r a b c d <<< "$1"
    echo $(( (a<<24) + (b<<16) + (c<<8) + d ))
}

uint2ip() {
    local u=$1
    echo "$(( (u>>24)&255 )).$(( (u>>16)&255 )).$(( (u>>8)&255 )).$(( u&255 ))"
}

# 生成网段内主机 IP（netwok+1 ~ broadcast-1），结果写入全局 HOSTS
gen_subnet_hosts() {
    local ip=$1 prefix=$2
    HOSTS=()
    if [ "$prefix" -lt 1 ] || [ "$prefix" -gt 32 ]; then return 1; fi
    local maxu=4294967295
    local masku=$(( ( ( (1<<prefix) - 1 ) << (32-prefix) ) & maxu ))
    local ipu network invmask broadcast total u
    ipu=$(ip2uint "$ip")
    network=$(( (ipu & masku) & maxu ))
    invmask=$(( (maxu ^ masku) & maxu ))
    broadcast=$(( (network | invmask) & maxu ))
    total=$(( broadcast - network - 1 ))
    if [ "$total" -lt 1 ] || [ "$total" -gt 65534 ]; then return 1; fi
    for (( u=network+1; u<broadcast; u++ )); do
        HOSTS+=("$(uint2ip $u)")
    done
    return 0
}

# 枚举全部可用网卡，写入全局 NIC_* 并行数组，返回候选数量（0 = 无）
# 每项: NIC_NAMES[i]=接口名  NIC_IPS[i]=IP  NIC_PREFIXES[i]=前缀  NIC_STATES[i]="1"(已连接)/"0"(未连接)
list_active_ipv4() {
    NIC_NAMES=(); NIC_IPS=(); NIC_PREFIXES=(); NIC_STATES=()
    local iface line ip prefix devpath state nm s ip_link_ok

    if [ "$HAVE_IPROUTE" -eq 1 ]; then
        local outp recline
        outp=$(ip -4 -o addr show 2>/dev/null)
        if [ -n "$outp" ]; then
            while IFS= read -r recline; do
                # 形如: 2: eth0    inet 192.168.1.5/24 brd ... scope global eth0
                iface=$(printf '%s' "$recline" | awk '{gsub(":","",$2); print $2}')
                line=$(printf '%s' "$recline" | awk '/inet[[:space:]]/ {print $4}')
                [ -n "$line" ] || continue
                [ "$iface" = "lo" ] && continue
                ip=${line%/*}; prefix=${line#*/}
                case "$ip" in 127.*|169.254.*) continue;; esac
                # 连接状态：operstate
                state=1
                devpath="/sys/class/net/$iface/operstate"
                if [ -r "$devpath" ]; then
                    s=$(cat "$devpath" 2>/dev/null)
                    [ "$s" = "up" ] || state=0
                else
                    ip_link_ok=$(ip link show dev "$iface" 2>/dev/null | grep -q ",UP," && echo 1 || echo 0)
                    [ "$ip_link_ok" -eq 1 ] || state=0
                fi
                NIC_NAMES+=("$iface")
                NIC_IPS+=("$ip")
                NIC_PREFIXES+=("$prefix")
                NIC_STATES+=("$state")
            done <<< "$outp"
        fi
        if [ "${#NIC_NAMES[@]}" -eq 0 ] && [ -d /sys/class/net ]; then
            for devpath in /sys/class/net/*; do
                [ -e "$devpath" ] || continue
                iface=$(basename "$devpath")
                [ "$iface" = "lo" ] && continue
                state=$(cat "$devpath/operstate" 2>/dev/null)
                [ "$state" = "up" ] || continue
                line=$(ip -4 addr show dev "$iface" 2>/dev/null | awk '/inet[[:space:]]/ {print $2; exit}')
                [ -n "$line" ] || continue
                ip=${line%/*}; prefix=${line#*/}
                case "$ip" in 127.*|169.254.*) continue;; esac
                NIC_NAMES+=("$iface")
                NIC_IPS+=("$ip")
                NIC_PREFIXES+=("$prefix")
                NIC_STATES+=(1)
            done
        fi
    fi

    if [ "${#NIC_NAMES[@]}" -eq 0 ] && [ "$HAVE_IFCONFIG" -eq 1 ]; then
        # ifconfig 回退：逐接口解析 inet 与 UP
        local outf nxt thisip thisprefix thisup
        outf=$(ifconfig 2>/dev/null)
        nxt=""; thisip=""; thisprefix=24; thisup=0
        while IFS= read -r line; do
            if [ -z "${line##*[![:space:]]*}" ]; then
                case "$line" in
                  *flags=*)
                    if [ -n "$nxt" ] && [ -n "$thisip" ]; then
                        case "$thisip" in 127.*|169.254.*) ;; *)
                            NIC_NAMES+=("$nxt"); NIC_IPS+=("$thisip"); NIC_PREFIXES+=("$thisprefix"); NIC_STATES+=("$thisup")
                        esac
                    fi
                    nxt=$(printf '%s' "$line" | awk '{print $1}' | tr -d ':')
                    case "$line" in *",UP,>"*) thisup=1;; *",UP,"*) thisup=1;; *) thisup=0;; esac
                    thisip=""; thisprefix=24
                    ;;
                  inet[[:space:]]*)
                    thisip=$(printf '%s' "$line" | awk '{print $2}')
                    nm=$(printf '%s' "$line" | awk '/netmask/ {for(i=1;i<=NF;i++) if($i=="netmask"){print $(i+1);break}}')
                    if [ -n "$nm" ]; then
                        thisprefix=$(netmask_to_prefix "$nm")
                    else
                        thisprefix=24
                    fi
                    ;;
                esac
            fi
        done <<< "$outf"
        if [ -n "$nxt" ] && [ -n "$thisip" ]; then
            case "$thisip" in 127.*|169.254.*) ;; *)
                NIC_NAMES+=("$nxt"); NIC_IPS+=("$thisip"); NIC_PREFIXES+=("$thisprefix"); NIC_STATES+=("$thisup")
            esac
        fi
    fi

    # 候选写入全局 NIC_* 数组；调用方必须直接调用（勿用 $( ) 命令替换，避免子 shell 丢失全局）
    return 0
}

netmask_to_prefix() {
    local nm=$1 v=0 n=0 p=0 o=0
    case "$nm" in
        0x*)
            v=$(( nm ))
            for (( n=31; n>=0; n-- )); do
                [ $(( (v>>n)&1 )) -eq 1 ] && ((p++)) || { [ "$p" -gt 0 ] && break; }
            done
            echo "$p"
            ;;
        *)
            local IFS=. saved
            set -- $nm
            for o in "$@"; do
                n=$o
                while [ "$n" -gt 0 ]; do ((p+=(n&1))); n=$((n>>1)); done
            done
            echo "$p"
            ;;
    esac
}

# 自动识别本机网段（取首个候选），输出 "ip prefix"，失败返回 1
get_active_ipv4() {
    list_active_ipv4 >/dev/null
    if [ "${#NIC_NAMES[@]}" -gt 0 ]; then
        echo "${NIC_IPS[0]} ${NIC_PREFIXES[0]}"
        return 0
    fi
    return 1
}

# ==================================================
# 小工具
# ==================================================

ms2sec() {
    local s=$(( ( ($1) + 999 ) / 1000 ))
    [ "$s" -lt 1 ] && s=1
    echo "$s"
}

join_by() {
    local d=$1; shift
    local out=""; local x
    for x in "$@"; do
        [ -n "$out" ] && out+="$d"
        out+="$x"
    done
    echo "$out"
}

valid_mac() {
    local m=$1
    m=$(printf '%s' "$m" | tr '[:lower:]' '[:upper:]' | tr ':' '-')
    case "$m" in
        ""|"00-00-00-00-00-00"|"FF-FF-FF-FF-FF-FF") echo "";;
        *) echo "$m";;
    esac
}

get_mac() {
    local ip=$1 mac=""
    if [ "$HAVE_IPROUTE" -eq 1 ]; then
        mac=$(ip neigh show "$ip" 2>/dev/null | awk '/lladdr/ {print $5; exit}')
        mac=$(valid_mac "$mac")
    fi
    if [ -z "$mac" ]; then
        mac=$(awk -v ip="$ip" '$1==ip && length($4)==17 && $4!="00:00:00:00:00:00" && $4!="ff:ff:ff:ff:ff:ff" {print $4; exit}' /proc/net/arp 2>/dev/null)
        mac=$(valid_mac "$mac")
    fi
    echo "${mac:-N/A}"
}

# 结束确认：交互模式等待回车，非交互直接退出
exit_wait() {
    local rc=${1:-0}
    if [ "$INTERACTIVE" -eq 1 ]; then
        read -p "[结束] 按回车键退出..."
    fi
    exit "$rc"
}

# ==================================================
# 步骤 2：Ping 存活扫描（每批 128 并发）
# ==================================================

ping_sweep() {
    local pt_ms=$1
    local pt_sec=$(( pt_ms / 1000 ))
    [ "$pt_sec" -lt 1 ] && pt_sec=1
    local total=$(( ( ${#HOSTS[@]} + 127 ) / 128 ))
    local n=${#HOSTS[@]} batch=0 i j ip t0 now tmpdir
    ALIVE=()
    [ "$n" -eq 0 ] && return
    tmpdir=$(mktemp -d)
    for (( i=0; i<n; i+=128 )); do
        (( batch++ ))
        t0=$(date +%s)
        for (( j=i; j<n && j<i+128; j++ )); do
            ip="${HOSTS[$j]}"
            ( "$TMO" $((pt_sec+2)) ping -c1 -W "$pt_sec" "$ip" >/dev/null 2>&1 && echo "$ip" > "$tmpdir/a.$j" ) &
        done
        wait
        now=$(date +%s)
        echo "  Ping 批次 $batch/$total，已用 $(( now - t0 ))s"
    done
    while IFS= read -r ip; do
        [ -n "$ip" ] && ALIVE+=("$ip")
    done < <(cat "$tmpdir"/a.* 2>/dev/null)
    rm -rf "$tmpdir"
}

# ==================================================
# 步骤 3：TCP 端口扫描（每批 128 并发）
# ==================================================

scan_tcp_ports() {
    local tm=$1
    local tsec=$(( ( tm + 999 ) / 1000 ))
    [ "$tsec" -lt 1 ] && tsec=1
    local pairs=() ip port
    local a
    for ip in "${ALIVE[@]}"; do
        for port in "${SCAN_PORTS[@]}"; do
            pairs+=("$ip:$port")
        done
    done
    local n=${#pairs[@]} total batch=0 i j pair
    OPEN_PAIRS=()
    [ "$n" -eq 0 ] && return
    total=$(( ( n + 127 ) / 128 ))
    local t0 now tmpdir
    tmpdir=$(mktemp -d)
    for (( i=0; i<n; i+=128 )); do
        (( batch++ ))
        t0=$(date +%s)
        for (( j=i; j<n && j<i+128; j++ )); do
            pair="${pairs[$j]}"
            ip="${pair%:*}"; port="${pair##*:}"
            ( "$TMO" $((tsec+1)) bash -c "exec 3<>/dev/tcp/$ip/$port" >/dev/null 2>&1 && echo "$pair" > "$tmpdir/o.$j" ) &
        done
        wait
        now=$(date +%s)
        echo "  端口批次 $batch/$total，已用 $(( now - t0 ))s"
    done
    while IFS= read -r pair; do
        [ -n "$pair" ] && OPEN_PAIRS+=("$pair")
    done < <(cat "$tmpdir"/o.* 2>/dev/null)
    rm -rf "$tmpdir"
}

# ==================================================
# 步骤 4：协议握手复核
# ==================================================

# 通用：读文本（HTTP/SSH/220 banner 等）
# 参数: $1=ip $2=port $3=secs $4=request(可直接传含 \r\n 的请求文本, 可为空) $5=maxbytes
read_text() {
    local ip=$1 port=$2 secs=$3 req=$4 max=$5
    local tsec=$((secs+1))
    if [ -n "$req" ]; then
        remote_ip="$ip" remote_port="$port" REQ="$req" "$TMO" "$tsec" bash -c '
            exec 3<>/dev/tcp/"$remote_ip"/"$remote_port" 2>/dev/null || exit 1
            printf '\''%b'\'' "$REQ" >&3 2>/dev/null
            cat <&3 2>/dev/null | head -c '"$max"'
        '
    else
        remote_ip="$ip" remote_port="$port" "$TMO" "$tsec" bash -c '
            exec 3<>/dev/tcp/"$remote_ip"/"$remote_port" 2>/dev/null || exit 1
            cat <&3 2>/dev/null | head -c '"$max"'
        '
    fi
}

# 通用：读二进制并转为连续 hex
# 参数: $1=ip $2=port $3=secs $4=request(\x 转义文本) $5=maxbytes
read_hex() {
    local ip=$1 port=$2 secs=$3 rawreq=$4 max=$5
    local tsec=$((secs+1))
    remote_ip="$ip" remote_port="$port" REQ="$rawreq" "$TMO" "$tsec" bash -c '
        exec 3<>/dev/tcp/"$remote_ip"/"$remote_port" 2>/dev/null || exit 1
        printf '\''%b'\'' "$REQ" >&3 2>/dev/null
        dd bs=1 count='"$max"' <&3 2>/dev/null | od -An -v -tx1
    '
}

# HTTP / HTTPS（openssl）
parse_http_resp() {
    local resp=$1 code server
    code=$(printf '%s' "$resp" | sed -n '1p' | tr -d '\r' | grep -oE '^HTTP/1\.[01][[:space:]]+[0-9]{3}' | grep -oE '[0-9]{3}$')
    [ -n "$code" ] || return 1
    server=$(printf '%s' "$resp" | sed -n 's/^[Ss]erver:[[:space:]]*//p' | tr -d '\r' | head -n1)
    echo "$code|$server"
    return 0
}

probe_http() {
    local ip=$1 port=$2 tm=$3 secs resp out req
    secs=$(ms2sec "$tm")
    req="GET / HTTP/1.0\r\nHost: ${ip}\r\nUser-Agent: Device-Scanner\r\nConnection: close\r\n\r\n"
    resp=$(read_text "$ip" "$port" "$secs" "$req" 4096)
    [ -n "$resp" ] || return 1
    out=$(parse_http_resp "$resp") && { echo "$out"; return 0; }
    return 1
}

probe_https() {
    local ip=$1 port=$2 tm=$3 secs resp out req
    [ "$OPENSSL_MISSING" -eq 0 ] || return 2
    secs=$(ms2sec "$tm")
    local tsec=$((secs+2))
    req="GET / HTTP/1.0\r\nHost: ${ip}\r\nUser-Agent: Device-Scanner\r\nConnection: close\r\n\r\n"
    resp=$({ printf '%b' "$req"; } \
        | "$TMO" "$tsec" openssl s_client -quiet -connect "$ip:$port" -servername "$ip" </dev/null 2>/dev/null | head -c 4096)
    [ -n "$resp" ] || return 1
    out=$(parse_http_resp "$resp") && { echo "$out"; return 0; }
    return 1
}

probe_ssh() {
    local ip=$1 port=$2 tm=$3 secs resp first
    secs=$(ms2sec "$tm")
    resp=$(read_text "$ip" "$port" "$secs" "" 2048)
    [ -n "$resp" ] || return 1
    first=$(printf '%s\n' "$resp" | sed -n '1p' | tr -d '\r')
    if printf '%s' "$first" | grep -qE '^SSH-[0-9][0-9.]*'; then
        echo "0|$first"; return 0
    fi
    return 1
}

probe_banner220() { # FTP / SMTP
    local ip=$1 port=$2 tm=$3 secs resp first
    secs=$(ms2sec "$tm")
    resp=$(read_text "$ip" "$port" "$secs" "" 2048)
    [ -n "$resp" ] || return 1
    first=$(printf '%s\n' "$resp" | sed -n '1p' | tr -d '\r')
    if printf '%s' "$first" | grep -qE '^220[-[:space:]]'; then
        echo "0|$first"; return 0
    fi
    return 1
}

probe_rtsp() {
    local ip=$1 port=$2 tm=$3 secs resp code server req
    secs=$(ms2sec "$tm")
    req="OPTIONS rtsp://${ip}:${port}/ RTSP/1.0\r\nCSeq: 1\r\nUser-Agent: Device-Scanner\r\n\r\n"
    resp=$(read_text "$ip" "$port" "$secs" "$req" 2048)
    [ -n "$resp" ] || return 1
    code=$(printf '%s' "$resp" | sed -n '1p' | tr -d '\r' | grep -oE '^RTSP/1\.0[[:space:]]+[0-9]{3}' | grep -oE '[0-9]{3}$')
    [ -n "$code" ] || return 1
    server=$(printf '%s' "$resp" | sed -n 's/^[Ss]erver:[[:space:]]*//p' | tr -d '\r' | head -n1)
    echo "$code|$server"; return 0
}

probe_sip() {
    local ip=$1 port=$2 tm=$3 secs resp code server req
    secs=$(ms2sec "$tm")
    req="OPTIONS sip:scanner@${ip} SIP/2.0\r\nVia: SIP/2.0/TCP 192.0.2.1:5060;branch=z9hG4bK7766\r\nMax-Forwards: 70\r\nTo: <sip:scanner@${ip}>\r\nFrom: <sip:scanner@${ip}>;tag=8877\r\nCall-ID: 1a2b3c@${ip}\r\nCSeq: 1 OPTIONS\r\nContent-Length: 0\r\n\r\n"
    resp=$(read_text "$ip" "$port" "$secs" "$req" 2048)
    [ -n "$resp" ] || return 1
    code=$(printf '%s' "$resp" | sed -n '1p' | tr -d '\r' | grep -oE '^SIP/2\.0[[:space:]]+[0-9]{3}' | grep -oE '[0-9]{3}$')
    [ -n "$code" ] || return 1
    server=$(printf '%s' "$resp" | sed -n 's/^[Ss]erver:[[:space:]]*//p' | tr -d '\r' | head -n1)
    echo "$code|$server"; return 0
}

probe_telnet() {
    local ip=$1 port=$2 tm=$3 secs resp text
    secs=$(ms2sec "$tm")
    resp=$(read_text "$ip" "$port" "$secs" "" 2048)
    text=$(printf '%s' "$resp" | LC_ALL=C tr -c '\011\012\015\040-\176' ' ' | LC_ALL=C tr -s ' ')
    text=$(printf '%s' "$text" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [ -n "$text" ] || text="Telnet"
    echo "0|$text"; return 0
}

probe_rdp() {
    local ip=$1 port=$2 tm=$3 secs hex
    secs=$(ms2sec "$tm")
    hex=$(read_hex "$ip" "$port" "$secs" "$RDP_REQ" 64)
    hex=${hex//[^0-9a-fA-F]/}
    [ "${#hex}" -ge 4 ] || return 1
    case "$hex" in
        0300*) echo "0|RDP"; return 0;;
    esac
    return 1
}

probe_mqtt() {
    local ip=$1 port=$2 tm=$3 secs hex
    secs=$(ms2sec "$tm")
    hex=$(read_hex "$ip" "$port" "$secs" "$MQTT_REQ" 64)
    hex=${hex//[^0-9a-fA-F]/}
    [ "${#hex}" -ge 8 ] || return 1
    if [ "${hex:0:2}" = "20" ] && [ "${hex:6:2}" = "00" ]; then
        echo "0|MQTT"; return 0
    fi
    return 1
}

probe_redis() {
    local ip=$1 port=$2 tm=$3 secs resp
    secs=$(ms2sec "$tm")
    resp=$(read_text "$ip" "$port" "$secs" 'PING\r\n' 256)
    [ -n "$resp" ] || return 1
    if printf '%s' "$resp" | grep -q '^+PONG'; then
        echo "0|Redis"; return 0
    fi
    return 1
}

probe_smb() {
    local ip=$1 port=$2 tm=$3 secs hex dialect=""
    secs=$(ms2sec "$tm")
    hex=$(read_hex "$ip" "$port" "$secs" "$SMB_REQ" 256)
    hex=${hex//[^0-9a-fA-F]/}
    if [ "${#hex}" -ge 16 ] && [ "${hex:8:8}" = "fe534d42" ]; then
        if [ "${#hex}" -ge 148 ]; then
            dialect=$(printf 'SMB 0x%04X' $(( 0x${hex:144:4} )))
        fi
        echo "0|$dialect"; return 0
    fi
    return 1
}

# 按协议分发探测，输出 "code|server"
probe_by_proto() {
    local proto=$1 ip=$2 port=$3 tm=$4
    case "$proto" in
        HTTP)   probe_http      "$ip" "$port" "$tm";;
        HTTPS)  probe_https     "$ip" "$port" "$tm";;
        SSH)    probe_ssh       "$ip" "$port" "$tm";;
        FTP)    probe_banner220 "$ip" "$port" "$tm";;
        SMTP)   probe_banner220 "$ip" "$port" "$tm";;
        RTSP)   probe_rtsp      "$ip" "$port" "$tm";;
        Telnet) probe_telnet    "$ip" "$port" "$tm";;
        RDP)    probe_rdp       "$ip" "$port" "$tm";;
        SMB)    probe_smb       "$ip" "$port" "$tm";;
        SIP)    probe_sip       "$ip" "$port" "$tm";;
        MQTT)   probe_mqtt      "$ip" "$port" "$tm";;
        Redis)  probe_redis     "$ip" "$port" "$tm";;
    esac
}

is_protocol_port() {
    local p=$1 pp
    for pp in ${PROTO_PORTS[$SELECTED_IDX]}; do
        [ "$pp" = "$p" ] && return 0
    done
    return 1
}

is_extra_port() {
    local p=$1 e
    for e in "${EXTRA_PORTS[@]}"; do
        [ "$e" = "$p" ] && return 0
    done
    return 1
}

# ==================================================
# 菜单
# ==================================================

get_selected_protocol() {
    local name=$1 up i
    [ -z "$name" ] && return 1
    up=$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')
    for (( i=0; i<PROTO_COUNT; i++ )); do
        [ "${PROTO_NAMES[$i]}" = "$up" ] && { echo "$i"; return 0; }
    done
    return 1
}

show_protocol_menu() {
    local i choice
    while true; do
        echo "[输入] 请选择要检测的协议（每次只能选择 1 种）："
        for (( i=0; i<PROTO_COUNT; i++ )); do
            printf "  %2d. %-8s  端口: %s\n" $((i+1)) "${PROTO_NAMES[$i]}" "${PROTO_PORTS[$i]}"
        done
        echo ""
        read -p "[输入] 请输入选项数字 [1 - ${PROTO_COUNT} / q 取消] 然后按回车: " choice
        if [[ "$choice" =~ ^[qQ]$ ]]; then
            return 1
        fi
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$PROTO_COUNT" ]; then
            SELECTED_IDX=$((choice-1))
            return 0
        fi
        echo "[错误] 无效输入，请输入 1 - ${PROTO_COUNT} 或 q。"
        echo ""
    done
}

# 按接口名或 IP 匹配候选网卡，成功填入 NIC_SEL_* 并返回 0
resolve_interface() {
    local key=$1 i
    [ -z "$key" ] && return 1
    for (( i=0; i<${#NIC_NAMES[@]}; i++ )); do
        if [ "${NIC_NAMES[$i]}" = "$key" ] || [ "${NIC_IPS[$i]}" = "$key" ]; then
            NIC_SEL_NAME="${NIC_NAMES[$i]}"
            NIC_SEL_IP="${NIC_IPS[$i]}"
            NIC_SEL_PREFIX="${NIC_PREFIXES[$i]}"
            return 0
        fi
    done
    return 1
}

nic_state_label() {
    local s=$1
    [ "$s" = "1" ] && echo "已连接" || echo "未连接"
}

show_nic_menu() {
    local count=${#NIC_NAMES[@]} i choice
    [ "$count" -eq 0 ] && return 1
    while true; do
        echo "[输入] 请选择要检测的网卡 [1 - ${count} / q 取消]:"
        for (( i=0; i<count; i++ )); do
            printf "  %2d. %-10s  %s/%-2s  [%s]\n" $((i+1)) "${NIC_NAMES[$i]}" "${NIC_IPS[$i]}" "${NIC_PREFIXES[$i]}" "$(nic_state_label "${NIC_STATES[$i]}")"
        done
        echo ""
        read -p "[输入] 请输入选项数字 [1 - ${count} / q 取消] 然后按回车: " choice
        if [[ "$choice" =~ ^[qQ]$ ]]; then
            return 1
        fi
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$count" ]; then
            NIC_SEL_NAME="${NIC_NAMES[$((choice-1))]}"
            NIC_SEL_IP="${NIC_IPS[$((choice-1))]}"
            NIC_SEL_PREFIX="${NIC_PREFIXES[$((choice-1))]}"
            return 0
        fi
        echo "[错误] 无效输入，请输入 1 - ${count} 或 q。"
        echo ""
    done
}

# ==================================================
# 参数解析与校验
# ==================================================

validate_cidr() {
    local s=$1 ip prefix o
    [[ "$s" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || return 1
    ip="${s%/*}"; prefix="${s#*/}"
    [ "$prefix" -ge 1 ] && [ "$prefix" -le 32 ] || return 1
    local IFS=.
    for o in $ip; do
        [[ "$o" =~ ^[0-9]+$ ]] || return 1
        [ "${#o}" -gt 1 ] && [ "${o:0:1}" = "0" ] && return 1
        [ "$o" -le 255 ] || return 1
    done
    return 0
}

parse_ports_arg() {
    local raw=$1 p IFS=,
    EXTRA_PORTS=()
    if [ -z "$raw" ]; then
        return 0
    fi
    for p in $raw; do
        p=$(printf '%s' "$p" | tr -d ' ')
        [[ "$p" =~ ^[0-9]+$ ]] || return 1
        [ "$p" -ge 1 ] && [ "$p" -le 65535 ] || return 1
        EXTRA_PORTS+=("$p")
    done
    return 0
}

# ==================================================
# 主流程
# ==================================================

main() {
    # ---- 解析命令行参数 ----
    local argv=("$@") i
    for (( i=0; i<${#argv[@]}; i++ )); do
        case "${argv[$i]}" in
            -Subnet)       SUBNET="${argv[$((i+1))]}"; ((i++));;
            -Interface)    IFACE_ARG="${argv[$((i+1))]}"; ((i++));;
            -Protocol)     PROTO_ARG="${argv[$((i+1))]}"; ((i++));;
            -Ports)        PORTS_ARG="${argv[$((i+1))]}"; ((i++));;
            -TimeoutMs)    TIMEOUT_MS="${argv[$((i+1))]}"; ((i++));;
            -PingTimeoutMs) PING_TIMEOUT_MS="${argv[$((i+1))]}"; ((i++));;
            -OutFile)      OUTFILE="${argv[$((i+1))]}"; ((i++));;
            *)
                echo "[错误] 未知参数: ${argv[$i]}（可用: -Subnet / -Interface / -Protocol / -Ports / -TimeoutMs / -PingTimeoutMs / -OutFile）"
                exit_wait 0
                ;;
        esac
    done

    if [[ "$TIMEOUT_MS" =~ ^[0-9]+$ ]] && [ "$TIMEOUT_MS" -ge 0 ]; then :; else
        echo "[错误] TimeoutMs 必须为非负整数。"
        exit_wait 0
    fi
    if [[ "$PING_TIMEOUT_MS" =~ ^[0-9]+$ ]] && [ "$PING_TIMEOUT_MS" -ge 0 ]; then :; else
        echo "[错误] PingTimeoutMs 必须为非负整数。"
        exit_wait 0
    fi
    if ! parse_ports_arg "$PORTS_ARG"; then
        echo "[错误] Ports 格式错误，应为逗号分隔的端口号，例如 8080,8443。"
        exit_wait 0
    fi

    # ---- 工具检查 ----
    local miss=()
    [ -n "$TMO" ] || miss+=("timeout")
    command -v ping  >/dev/null 2>&1 || miss+=("ping")
    command -v od    >/dev/null 2>&1 || miss+=("od")
    command -v dd    >/dev/null 2>&1 || miss+=("dd")
    command -v mktemp >/dev/null 2>&1 || miss+=("mktemp")
    [ "$HAVE_IPROUTE" -eq 1 ] || [ "$HAVE_IFCONFIG" -eq 1 ] || miss+=("ip 或 ifconfig")
    if [ "${#miss[@]}" -gt 0 ]; then
        echo "[错误] 缺少必需工具: $(join_by , "${miss[@]}")。请安装后重试（如: sudo apt install iproute2 coreutils）"
        exit_wait 0
    fi

    # ---- 启动横幅 ----
    echo "$SEP"
    echo "            设备协议检测工具"
    echo "            版本 1.1"
    echo "$SEP"
    echo "[适用场景]"
    echo "需要识别局域网内设备开放的端口与协议服务（HTTP、SSH、FTP、RTSP、RDP 等）时使用。"
    echo ""
    echo "[功能说明]"
    echo "自动识别本机网卡（多网卡时可选择需要检测的网卡），扫描存活主机，并按所选协议做端口检测与握手复核，输出每台设备的 IP、MAC 与服务信息。"
    echo ""
    echo "[操作方式]"
    echo "输入选项数字选择 1 种协议后按回车，输入 q 取消；多网卡时需再选择检测网卡；随后确认扫描参数后自动执行。"
    echo ""
    echo "[执行步骤]"
    echo "1. 识别网卡与待扫描主机"
    echo "2. Ping 扫描存活主机"
    echo "3. 检测开放端口"
    echo "4. 协议握手复核"
    echo ""
    echo "[注意事项]"
    echo "- 每次运行仅检测 1 种协议；可用 -Ports 附加原始端口（仅做 TCP 开放检测）。"
    echo "- 多网卡环境可用 -Interface <接口名或IP> 指定网卡，或用 -Subnet 直接指定网段。"
    echo "- 扫描整个网段耗时较长，请耐心等待。"
    echo "- 需在可访问目标网段的网络环境下运行。"
    if [ "$OPENSSL_MISSING" -eq 1 ]; then
        echo "- 未检测到 openssl，HTTPS 协议将降级为仅 TCP 开放检测；安装后可恢复（如: sudo apt install openssl）。"
    fi
    echo "$SEP"

    local sw_total
    sw_total=$(date +%s)

    # ---- 收集参数：协议 ----
    local sel_rc
    SELECTED_IDX=$(get_selected_protocol "$PROTO_ARG")
    sel_rc=$?
    if [ "$sel_rc" -ne 0 ] && [ -n "$PROTO_ARG" ]; then
        echo ""
        echo "[错误] 未知协议: $PROTO_ARG（可用: $(join_by , "${PROTO_NAMES[@]}")）。"
    fi
    if [ -z "$SELECTED_IDX" ] || [ "$SELECTED_IDX" -lt 0 ]; then
        if [ "$INTERACTIVE" -ne 1 ]; then
            echo ""
            echo "[错误] 未指定有效协议，且非交互模式下无法弹出菜单，请使用 -Protocol 指定。"
            exit 1
        fi
        echo ""
        if ! show_protocol_menu; then
            echo "[提示] 已取消，未开始扫描。"
            echo ""
            exit_wait 0
        fi
    fi
    SELECTED_PROTO="${PROTO_NAMES[$SELECTED_IDX]}"

    # ---- 收集参数：网段 / 网卡 ----
    local local_ip="" prefix="" nic_name=""
    if [ -n "$SUBNET" ]; then
        if validate_cidr "$SUBNET"; then
            local_ip="${SUBNET%/*}"
            prefix="${SUBNET#*/}"
        else
            echo ""
            echo "[错误] Subnet 格式错误，应为 CIDR 格式，例如 192.168.1.0/24。"
            echo "[提示] 已取消，未开始扫描。"
            echo ""
            exit_wait 0
        fi
    else
        list_active_ipv4 >/dev/null
        if [ "${#NIC_NAMES[@]}" -eq 0 ]; then
            echo ""
            echo "[错误] 无法自动识别网段，请使用 -Subnet 手动指定，例如 -Subnet 192.168.1.0/24。"
            echo "[提示] 已取消，未开始扫描。"
            echo ""
            exit_wait 0
        fi
        if [ -n "$IFACE_ARG" ]; then
            if ! resolve_interface "$IFACE_ARG"; then
                echo ""
                echo "[错误] 未找到匹配的网卡: $IFACE_ARG（接口名或 IP）。"
                local avail=() j
                for (( j=0; j<${#NIC_NAMES[@]}; j++ )); do
                    avail+=("${NIC_NAMES[$j]} (${NIC_IPS[$j]})")
                done
                echo "[提示] 可用网卡：$(join_by , "${avail[@]}")。"
                echo "[提示] 已取消，未开始扫描。"
                echo ""
                exit_wait 0
            fi
        elif [ "$INTERACTIVE" -eq 1 ]; then
            echo ""
            if ! show_nic_menu; then
                echo "[提示] 已取消，未开始扫描。"
                echo ""
                exit_wait 0
            fi
        else
            NIC_SEL_NAME="${NIC_NAMES[0]}"
            NIC_SEL_IP="${NIC_IPS[0]}"
            NIC_SEL_PREFIX="${NIC_PREFIXES[0]}"
        fi
        local_ip="$NIC_SEL_IP"
        prefix="$NIC_SEL_PREFIX"
        nic_name="$NIC_SEL_NAME"
    fi

    # ---- 汇总待扫描端口 ----
    local plist="${PROTO_PORTS[$SELECTED_IDX]}"
    local e
    for e in "${EXTRA_PORTS[@]}"; do
        plist+=" $e"
    done
    SCAN_PORTS=()
    while IFS= read -r p; do
        [ -n "$p" ] && SCAN_PORTS+=("$p")
    done < <(printf '%s\n' $plist | tr ' ' '\n' | sed '/^[[:space:]]*$/d' | sort -nu)

    # ---- 参数回显确认 ----
    echo ""
    echo "[提示] 扫描参数确认："
    echo "  检测协议: $SELECTED_PROTO（端口: ${PROTO_PORTS[$SELECTED_IDX]}）"
    if [ -n "$nic_name" ]; then
        echo "  检测网卡: $nic_name"
    fi
    echo "  扫描网段: $local_ip/$prefix"
    echo "  检测端口: $(join_by , "${SCAN_PORTS[@]}")"
    if [ "${#EXTRA_PORTS[@]}" -gt 0 ]; then
        echo "  附加原始端口: $(join_by , "${EXTRA_PORTS[@]}")"
    fi
    echo "  TCP 超时: ${TIMEOUT_MS}ms，Ping 超时: ${PING_TIMEOUT_MS}ms"
    if [ "$INTERACTIVE" -eq 1 ]; then
        local ok
        while true; do
            read -p "[输入] 确认开始扫描？[y 开始 / q 取消] " ok
            if [[ "$ok" =~ ^[yY]$ ]]; then break; fi
            if [[ "$ok" =~ ^[qQ]$ ]]; then
                echo "[提示] 已取消，未开始扫描。"
                echo ""
                exit_wait 0
            fi
            echo "[错误] 无效输入，请输入 y 或 q。"
        done
    fi

    # ---- 步骤 1/4：识别网卡与待扫描主机 ----
    echo ""
    echo "[进度] 步骤 1/4：识别网卡与待扫描主机 ..."
    gen_subnet_hosts "$local_ip" "$prefix"
    local self_u ip2u keep=()
    self_u=$(ip2uint "$local_ip")
    for host in "${HOSTS[@]}"; do
        ip2u=$(ip2uint "$host")
        [ "$ip2u" -ne "$self_u" ] && keep+=("$host")
    done
    HOSTS=("${keep[@]}")
    echo "[完成] 扫描网段 $local_ip/$prefix，待扫描主机 ${#HOSTS[@]} 台（已排除本机）。"

    # ---- 步骤 2/4：Ping 扫描存活主机 ----
    if [ "${#HOSTS[@]}" -gt 0 ]; then
        echo ""
        echo "[进度] 步骤 2/4：Ping 扫描存活主机 ..."
        ping_sweep "$PING_TIMEOUT_MS"
        echo "[完成] 存活主机 ${#ALIVE[@]} 台。"
    else
        echo "[提示] 网段内无可扫描主机，扫描中止。"
    fi

    # ---- 步骤 3/4：检测开放端口 ----
    if [ "${#ALIVE[@]}" -gt 0 ]; then
        echo ""
        echo "[进度] 步骤 3/4：检测开放端口 ..."
        scan_tcp_ports "$TIMEOUT_MS"
        echo "[完成] 开放端口对 ${#OPEN_PAIRS[@]} 个。"
    else
        echo "[提示] 未发现存活主机，跳过端口检测与协议复核。"
    fi

    # ---- 步骤 4/4：协议握手复核 ----
    if [ "${#OPEN_PAIRS[@]}" -gt 0 ]; then
        echo ""
        echo "[进度] 步骤 4/4：协议握手复核 ..."
        local count=0 total=${#OPEN_PAIRS[@]} pair ip port info pcode pserver matched
        local sorted_pairs=()
        while IFS= read -r pair; do
            [ -n "$pair" ] && sorted_pairs+=("$pair")
        done < <(printf '%s\n' "${OPEN_PAIRS[@]}" | sort)
        for pair in "${sorted_pairs[@]}"; do
            (( count++ ))
            if [ $(( count % 50 )) -eq 0 ] || [ "$count" -eq "$total" ]; then
                echo "  复核进度 $count/$total"
            fi
            ip="${pair%:*}"; port="${pair##*:}"
            matched=0
            if is_protocol_port "$port"; then
                info=$(probe_by_proto "$SELECTED_PROTO" "$ip" "$port" "$TIMEOUT_MS")
                local rc=$?
                if [ "$rc" -eq 0 ]; then
                    matched=1
                    IFS='|' read -r pcode pserver <<< "$info"
                    RESULTS+=("$SELECTED_PROTO|$ip|$(get_mac "$ip")|$port|$pcode|$pserver")
                elif [ "$rc" -eq 2 ]; then
                    # HTTPS / openssl 缺失 → 降级为仅 TCP 开放检测
                    matched=1
                    RESULTS+=("TCP|$ip|$(get_mac "$ip")|$port|0|(port open)")
                fi
            fi
            if [ "$matched" -eq 0 ] && is_extra_port "$port"; then
                RESULTS+=("TCP|$ip|$(get_mac "$ip")|$port|0|(port open)")
            fi
        done
        echo "[完成] 协议握手复核完成。"
    elif [ "${#ALIVE[@]}" -gt 0 ]; then
        echo "[提示] 未发现开放端口，跳过协议复核。"
    fi

    # ---- 结果汇总 ----
    local total_devices proto names ips r p ip mac port code server
    total_devices=$(printf '%s\n' "${RESULTS[@]}" | cut -d'|' -f2 | sort -u | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')

    if [ "${#RESULTS[@]}" -gt 0 ]; then
        while IFS= read -r proto; do
            [ -n "$proto" ] || continue
            echo ""
            echo "=== $proto 设备 ($(printf '%s\n' "${RESULTS[@]}" | grep "^${proto}|" | cut -d'|' -f2 | sort -u | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')) ==="
            show_table "$proto"
        done < <(printf '%s\n' "${RESULTS[@]}" | cut -d'|' -f1 | sort -u)
        echo ""
        echo "[结果] 发现设备总数: $total_devices 台。"
        if [ -n "$OUTFILE" ]; then
            export_csv "$OUTFILE"
            echo "[完成] 结果已导出: $OUTFILE"
        fi
    else
        echo ""
        echo "[提示] 有端口开放，但未通过任何协议复核。"
    fi

    echo ""
    echo "[结果] 扫描完成。"
    echo "  检测协议: $SELECTED_PROTO"
    echo "  扫描网段: $local_ip/$prefix"
    echo "  存活主机: ${#ALIVE[@]}"
    echo "  开放端口对: ${#OPEN_PAIRS[@]}"
    echo "  识别设备: $total_devices 台"
    echo "  共耗时: $(( $(date +%s) - sw_total ))s"
    echo ""
    echo "扫描结束。"
    echo ""
    exit_wait 0
}

# ---------- 结果表 ----------
show_table() {
    local proto=$1 rows=() r p ip mac port code server
    local w_ip=15 w_mac=17 w_port=6 w_code=6
    for r in "${RESULTS[@]}"; do
        IFS='|' read -r p ip mac port code server <<< "$r"
        [ "$p" = "$proto" ] || continue
        rows+=("$r")
        [ "${#ip}" -gt "$w_ip" ] && w_ip=${#ip}
        [ "${#mac}" -gt "$w_mac" ] && w_mac=${#mac}
        [ "${#port}" -gt "$w_port" ] && w_port=${#port}
        [ "${#code}" -gt "$w_code" ] && w_code=${#code}
    done
    [ "${#rows[@]}" -gt 0 ] || return 0
    printf "%-${w_ip}s  %-${w_mac}s  %-${w_port}s  %-${w_code}s  %s\n" "IP" "MAC" "Port" "Code" "Server"
    local dashlen=$(( w_ip + w_mac + w_port + w_code + 11 ))
    printf '%*s' "$dashlen" '' | tr ' ' '-'
    echo ""
    for r in "${rows[@]}"; do
        IFS='|' read -r p ip mac port code server <<< "$r"
        printf "%-${w_ip}s  %-${w_mac}s  %-${w_port}s  %-${w_code}s  %s\n" "$ip" "$mac" "$port" "$code" "$server"
    done
}

csv_esc() {
    local s=$1
    if printf '%s' "$s" | grep -q '[" ,]'; then
        printf '"%s"' "${s//\"/\"\"}"
    else
        printf '%s' "$s"
    fi
}

export_csv() {
    local f=$1 r p ip mac port code server rsorted=()
    while IFS= read -r r; do
        [ -n "$r" ] && rsorted+=("$r")
    done < <(printf '%s\n' "${RESULTS[@]}" | sort -t'|' -k1,1 -k2,2 -k4,4n)
    {
        printf '\xef\xbb\xbf'
        printf 'Protocol,IP,MAC,Port,Code,Server\n'
        for r in "${rsorted[@]}"; do
            IFS='|' read -r p ip mac port code server <<< "$r"
            printf '%s,%s,%s,%s,%s,%s\n' "$p" "$ip" "$mac" "$port" "$code" "$(csv_esc "$server")"
        done
    } > "$f"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi