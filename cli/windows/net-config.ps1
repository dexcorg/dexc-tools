# 网卡网络配置工具（PowerShell · UTF-8 无 BOM）
$null = chcp 65001
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$sep = '=' * 50

function Show-Banner {
    Write-Host $sep
    Write-Host "            网卡网络配置工具"
    Write-Host "            版本 1.0"
    Write-Host $sep
    Write-Host "[适用场景]"
    Write-Host "需要为指定网卡设置静态 IP 地址、子网掩码和默认网关，或查看网卡当前配置时使用。"
    Write-Host ""
    Write-Host "[功能说明]"
    Write-Host "本脚本将执行以下操作："
    Write-Host "  1. 列出本机所有网卡及其连接状态"
    Write-Host "  2. 显示所选网卡的当前 IP、子网掩码、默认网关与 MAC 地址"
    Write-Host "  3. 收集新的 IP、子网掩码、默认网关（网关可留空）"
    Write-Host "  4. 确认后应用静态 IP 配置"
    Write-Host ""
    Write-Host "[操作方式]"
    Write-Host "按提示输入网卡编号选择要操作的网卡，再依次输入新 IP、子网掩码、默认网关，"
    Write-Host "确认无误后输入 y 执行，输入 q 可随时取消。"
    Write-Host ""
    Write-Host "[执行步骤]"
    Write-Host "1. 选择要配置的网卡"
    Write-Host "2. 查看当前配置"
    Write-Host "3. 输入新的 IP、子网掩码、默认网关"
    Write-Host "4. 确认并应用配置"
    Write-Host ""
    Write-Host "[注意事项]"
    Write-Host "- 修改网卡 IP 可能导致本机网络短暂中断，请在确认前保存未完成的工作。"
    Write-Host "- 需要管理员权限，请右键以管理员身份运行。"
    Write-Host "- 网关留空则仅设置本机 IP 与子网掩码，不配置默认路由。"
    Write-Host $sep
}

# ---------- 管理员权限检查 ----------
try {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch {
    $isAdmin = $false
}

# ---------- 网卡列表（编号、名称、状态） ----------
function Get-NetAdapterList {
    $rows = @()
    try {
        $ads = @(Get-NetAdapter -ErrorAction SilentlyContinue)
        if ($ads.Count -gt 0) {
            foreach ($a in $ads) { $rows += [pscustomobject]@{ Name = $a.Name; State = $a.Status.ToString() } }
            return $rows
        }
    } catch { }
    $lines = & netsh interface show interface 2>$null
    for ($i = 3; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $state = ''
        $name = ''
        if ($line -match '^\S+\s+(\S+)\s+\S+\s+(.+)$') {
            $state = $Matches[1]
            $name = $Matches[2].Trim()
        }
        if ($name) { $rows += [pscustomobject]@{ Name = $name; State = $state } }
    }
    return $rows
}

# ---------- 当前配置（IP / 子网掩码 / 默认网关） ----------
function Get-NetConfig {
    param([string]$Name)
    $cfg = @{ IP = ''; Mask = ''; Gateway = '' }

    try {
        $ips = @(Get-NetIPAddress -InterfaceAlias $Name -AddressFamily IPv4 -ErrorAction SilentlyContinue)
        foreach ($ipCell in $ips) {
            if ($ipCell -and -not $cfg.IP -and $ipCell.IPAddress -and $ipCell.IPAddress -ne '0.0.0.0') { $cfg.IP = $ipCell.IPAddress }
            if ($ipCell -and -not $cfg.Mask -and $ipCell.PrefixLength -gt 0 -and $ipCell.PrefixLength -le 32) {
                $maskU = ([uint32]0xFFFFFFFF) -band (([uint32]0xFFFFFFFF) -shl (32 - [int]$ipCell.PrefixLength))
                $cfg.Mask = ([System.Net.IPAddress]$maskU).IPAddressToString
            }
        }
        $routes = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -AddressFamily IPv4 -ErrorAction SilentlyContinue)
        foreach ($r in $routes) {
            if ($r -and $r.InterfaceAlias -eq $Name -and $r.NextHop -and $r.NextHop -ne '0.0.0.0') { $cfg.Gateway = $r.NextHop; break }
        }
        if ($cfg.IP -and $cfg.Mask) { return $cfg }
    } catch { }

    $out = & netsh interface ip show addresses "name=$Name" 2>$null
    foreach ($line in $out) {
        if ($line -match 'IP Address:\s*(\S+)') { $cfg.IP = $Matches[1] }
        elseif ($line -match 'Subnet Mask:\s*(\S+)') { $cfg.Mask = $Matches[1] }
        elseif ($line -match 'Subnet Prefix:\s*[0-9.]+/\d+\s*\(mask\s+(\d{1,3}(?:\.\d{1,3}){3})\)') { $cfg.Mask = $Matches[1] }
        elseif ($line -match 'Subnet Prefix:\s*([0-9.]+)/') { $cfg.Mask = ([System.Net.IPAddress]::new($Matches[1]).ToString()) }
    }
    $gwOut = & netsh interface ip show route "interface=$Name" 2>$null
    foreach ($line in $gwOut) {
        if ($line -match '0\.0\.0\.0/0') {
            $gm = [regex]::Matches($line, '\b(\d{1,3}(?:\.\d{1,3}){3})\b')
            foreach ($g in $gm) { if ($g.Value -ne '0.0.0.0') { $cfg.Gateway = $g.Value } }
            if ($cfg.Gateway) { break }
        }
    }
    return $cfg
}

# ---------- MAC 地址（优先 Get-NetAdapter，回落 getmac） ----------
function Get-NetMac {
    param([string]$Name)
    $ad = Get-NetAdapter -Name $Name -ErrorAction SilentlyContinue
    if ($ad -and $ad.MacAddress) { return $ad.MacAddress }
    $lines = & getmac /v /nh 2>$null
    foreach ($line in $lines) {
        $m = [regex]::Match($line, '([0-9A-Fa-f]{2}[-:][0-9A-Fa-f]{2}[-:][0-9A-Fa-f]{2}[-:][0-9A-Fa-f]{2}[-:][0-9A-Fa-f]{2}[-:][0-9A-Fa-f]{2})')
        if ($m.Success -and ($line -like "*$Name*" -or $line -like "*$($Name.Split([char]40)[0].TrimEnd())*")) {
            return $m.Groups[1].Value
        }
    }
    return '未获取'
}

# ---------- 合法 IPv4 地址校验 ----------
function Test-IPv4 {
    param([string]$Value)
    $ip = $null
    return [System.Net.IPAddress]::TryParse($Value, [ref]$ip)
}

# ===== 主流程 =====
Show-Banner

if (-not $isAdmin) {
    Write-Host ""
    Write-Host "[提示] 未检测到管理员权限，修改网卡 IP 可能失败。"
    Write-Host "        建议关闭后右键以管理员身份运行。"
    $ok = Read-Host "[输入] 是否仍要继续？[y 继续 / n 取消]"
    if ($ok -notmatch '^[yY]$') {
        Write-Host "[提示] 已取消，未做任何修改。"
        Read-Host "[结束] 按回车键退出..."
        exit 0
    }
    Write-Host ""
}

# ---------- 步骤 1：选择网卡 ----------
Write-Host ""
Write-Host "[进度] 步骤 1/4：选择要配置的网卡 ..."
$adapters = @(Get-NetAdapterList)
if ($adapters.Count -eq 0) {
    Write-Host ""
    Write-Host "[错误] 未找到任何网络适配器。"
    Write-Host ""
    Read-Host "[结束] 按回车键退出..."
    exit 0
}

Write-Host ""
Write-Host "可用网络适配器列表："
Write-Host $sep
for ($i = 0; $i -lt $adapters.Count; $i++) {
    Write-Host ("  {0,2}. {1}  ({2})" -f ($i + 1), $adapters[$i].Name, $adapters[$i].State)
}
Write-Host $sep

$selIndex = -1
while ($true) {
    $raw = Read-Host ("[输入] 请输入要查看/配置的网卡编号 [1 - {0} / q 取消] 然后按回车" -f $adapters.Count)
    if ($raw -match '^[qQ]$') {
        Write-Host "[提示] 已取消，未做任何修改。"
        Read-Host "[结束] 按回车键退出..."
        exit 0
    }
    if ([int]::TryParse($raw, [ref]$selIndex) -and $selIndex -ge 1 -and $selIndex -le $adapters.Count) {
        break
    }
    Write-Host ("[错误] 无效输入，请输入 1 - {0} 或 q。" -f $adapters.Count)
}
$selAdapter = $adapters[$selIndex - 1]
Write-Host "[完成] 已选择网卡: $($selAdapter.Name)"
Write-Host ""

# ---------- 步骤 2：查看当前配置 ----------
Write-Host "[进度] 步骤 2/4：查看当前配置 ..."
$cfg = Get-NetConfig $selAdapter.Name
$mac = Get-NetMac $selAdapter.Name
$dispIP = if ($cfg.IP) { $cfg.IP } else { '未配置 (或 DHCP)' }
$dispMask = if ($cfg.Mask) { $cfg.Mask } else { '未配置' }
$dispGw = if ($cfg.Gateway) { $cfg.Gateway } else { '未设置（无网关）' }

Write-Host $sep
Write-Host ("     网卡 [ {0} ] 当前配置" -f $selAdapter.Name)
Write-Host $sep
Write-Host ("连接状态      : {0}" -f $selAdapter.State)
Write-Host ("IP 地址       : {0}" -f $dispIP)
Write-Host ("子网掩码      : {0}" -f $dispMask)
Write-Host ("默认网关      : {0}" -f $dispGw)
Write-Host ("MAC 地址      : {0}" -f $mac)
Write-Host $sep
Write-Host "[完成] 当前配置查看完毕。"
Write-Host ""

# 是否修改
while ($true) {
    $yn = Read-Host "[输入] 是否要修改此网卡的 IP 地址？[y 修改 / n 返回重新选择 / q 退出]"
    if ($yn -match '^[qQ]$') {
        Write-Host "[提示] 已取消，未做任何修改。"
        Read-Host "[结束] 按回车键退出..."
        exit 0
    }
    if ($yn -match '^[yY]$') { break }
    if ($yn -match '^[nN]$') {
        Write-Host "[提示] 返回重新选择网卡。"
        Write-Host ""
        Write-Host "[进度] 重新选择网卡 ..."
        $adapters = @(Get-NetAdapterList)
        if ($adapters.Count -eq 0) {
            Write-Host "[错误] 未找到任何网络适配器。"
            Read-Host "[结束] 按回车键退出..."
            exit 0
        }
        Write-Host ""
        Write-Host "可用网络适配器列表："
        Write-Host $sep
        for ($i = 0; $i -lt $adapters.Count; $i++) {
            Write-Host ("  {0,2}. {1}  ({2})" -f ($i + 1), $adapters[$i].Name, $adapters[$i].State)
        }
        Write-Host $sep
        $selIndex = -1
        while ($true) {
            $raw = Read-Host ("[输入] 请输入要查看/配置的网卡编号 [1 - {0} / q 取消] 然后按回车" -f $adapters.Count)
            if ($raw -match '^[qQ]$') {
                Write-Host "[提示] 已取消，未做任何修改。"
                Read-Host "[结束] 按回车键退出..."
                exit 0
            }
            if ([int]::TryParse($raw, [ref]$selIndex) -and $selIndex -ge 1 -and $selIndex -le $adapters.Count) {
                break
            }
            Write-Host ("[错误] 无效输入，请输入 1 - {0} 或 q。" -f $adapters.Count)
        }
        $selAdapter = $adapters[$selIndex - 1]
        Write-Host "[完成] 已选择网卡: $($selAdapter.Name)"
        $cfg = Get-NetConfig $selAdapter.Name
        $mac = Get-NetMac $selAdapter.Name
        $dispIP = if ($cfg.IP) { $cfg.IP } else { '未配置 (或 DHCP)' }
        $dispMask = if ($cfg.Mask) { $cfg.Mask } else { '未配置' }
        $dispGw = if ($cfg.Gateway) { $cfg.Gateway } else { '未设置（无网关）' }
        Write-Host ""
        Write-Host $sep
        Write-Host ("     网卡 [ {0} ] 当前配置" -f $selAdapter.Name)
        Write-Host $sep
        Write-Host ("连接状态      : {0}" -f $selAdapter.State)
        Write-Host ("IP 地址       : {0}" -f $dispIP)
        Write-Host ("子网掩码      : {0}" -f $dispMask)
        Write-Host ("默认网关      : {0}" -f $dispGw)
        Write-Host ("MAC 地址      : {0}" -f $mac)
        Write-Host $sep
        Write-Host ""
    }
}

Write-Host "[提示] 开始修改网卡 [ $($selAdapter.Name) ] 的 IP 设置。"
Write-Host ""

# ---------- 步骤 3：收集参数（3 个参数） ----------
Write-Host "[进度] 步骤 3/4：输入新的网络参数 ..."
$newIP = ''
while ($true) {
    $newIP = (Read-Host "[输入] 请输入新的 IP 地址 (参数 1/3，例如: 192.168.10.100)").Trim()
    if (Test-IPv4 $newIP) { break }
    Write-Host "[错误] 输入无效，请输入正确的 IP 地址格式（例如 192.168.10.100）。"
}
Write-Host "[完成] IP 地址: $newIP"

$newMask = ''
while ($true) {
    $newMask = (Read-Host "[输入] 请输入新的子网掩码 (参数 2/3，例如: 255.255.255.0)").Trim()
    if (Test-IPv4 $newMask) { break }
    Write-Host "[错误] 输入无效，请输入正确的子网掩码格式（例如 255.255.255.0）。"
}
Write-Host "[完成] 子网掩码: $newMask"

$newGateway = (Read-Host "[输入] 请输入新的默认网关 (参数 3/3，直接回车可留空)").Trim()
if ($newGateway -ne '') {
    if (-not (Test-IPv4 $newGateway)) {
        Write-Host "[错误] 网关格式无效，将按留空处理（不配置默认路由）。"
        $newGateway = ''
    }
}
Write-Host "[完成] 默认网关: $(if ($newGateway) { $newGateway } else { '(未设置)' })"

# ---------- 参数回显确认 ----------
Write-Host ""
Write-Host "[提示] 配置确认："
Write-Host $sep
Write-Host ("网卡名称: {0}" -f $selAdapter.Name)
Write-Host ("新 IP   : {0}" -f $newIP)
Write-Host ("子网掩码: {0}" -f $newMask)
if ($newGateway) { Write-Host ("默认网关: {0}" -f $newGateway) }
else { Write-Host "默认网关: (未设置)" }
Write-Host $sep
Write-Host "[提示] 执行后将修改所选网卡的 IP 配置，网络可能短暂中断。"

# ---------- 步骤 4：确认并应用 ----------
while ($true) {
    $confirm = Read-Host "[输入] 确认应用此配置？[y 应用 / q 取消]"
    if ($confirm -match '^[yY]$') { break }
    if ($confirm -match '^[qQ]$') {
        Write-Host "[提示] 操作已取消，未做任何修改。"
        Read-Host "[结束] 按回车键退出..."
        exit 0
    }
    Write-Host "[错误] 无效输入，请输入 y 或 q。"
}

Write-Host ""
Write-Host "[进度] 步骤 4/4：应用新的网卡配置 ..."
$cmdArgs = @('interface', 'ip', 'set', 'address', "name=$($selAdapter.Name)", 'static', $newIP, $newMask)
if ($newGateway) { $cmdArgs += @($newGateway) }
& netsh @cmdArgs 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Host "[完成] 网络配置已成功更新。"
    Write-Host ""
    $newCfg = Get-NetConfig $selAdapter.Name
    $dIP = if ($newCfg.IP) { $newCfg.IP } else { '未配置 (或 DHCP)' }
    $dMask = if ($newCfg.Mask) { $newCfg.Mask } else { '未配置' }
    $dGw = if ($newCfg.Gateway) { $newCfg.Gateway } else { '未设置（无网关）' }
    Write-Host "[结果] 更新后的配置："
    Write-Host ("  IP 地址 : {0}" -f $dIP)
    Write-Host ("  子网掩码: {0}" -f $dMask)
    Write-Host ("  默认网关: {0}" -f $dGw)
} else {
    Write-Host "[失败] 配置应用失败，请检查输入参数是否有有效（退出码: $LASTEXITCODE）。"
}

Write-Host ""
Write-Host "[结果] 本次配置流程结束。"
Read-Host "[结束] 按回车键退出..."
exit 0
