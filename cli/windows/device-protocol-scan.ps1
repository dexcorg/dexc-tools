<#
.SYNOPSIS
  设备协议检测工具（Windows / PowerShell 5.1 兼容）

.DESCRIPTION
  自动识别本机网卡，扫描存活主机，按用户选择的 1 种内置协议检测目标端口，
  并通过协议握手 / banner 复核确认服务类型，最终输出每台设备的 IP、MAC 与服务信息。
  每次运行仅检测 1 种协议。多网卡时可选择要检测的网卡。

  内置协议：HTTP HTTPS SSH FTP SMTP RTSP Telnet RDP SMB SIP MQTT Redis
  额外原始端口：通过 -Ports 追加，仅做 TCP 端口开放检测（TCP-only）。

.PARAMETER Subnet
  手动指定 CIDR 网段，例如 192.168.1.0/24。缺省自动识别本机网段，多网卡时交互选择。

.PARAMETER Interface
  指定要检测的网卡（接口名或 IP），例如 eth0。缺省多网卡时交互选择。

.PARAMETER Protocol
  要检测的协议名（每次 1 种），例如 -Protocol SSH；缺省进入交互菜单选择。

.PARAMETER Ports
  额外要检测的原始端口（TCP-only），例如 -Ports 8080,8443。

.PARAMETER TimeoutMs
  TCP 连接 / 读取超时（毫秒），默认 1500。

.PARAMETER PingTimeoutMs
  Ping 超时（毫秒），默认 500。

.PARAMETER OutFile
  可选，将全部结果导出为 CSV 文件。

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\device-protocol-scan.ps1
  powershell -NoProfile -ExecutionPolicy Bypass -File .\device-protocol-scan.ps1 -Protocol SSH
  powershell -NoProfile -ExecutionPolicy Bypass -File .\device-protocol-scan.ps1 -Protocol RTSP -Subnet 192.168.1.0/24
#>

param(
    [string]$Subnet,
    [string]$Interface,
    [string]$Protocol,
    [int[]]$Ports = @(),
    [int]$TimeoutMs = 1500,
    [int]$PingTimeoutMs = 500,
    [string]$OutFile
)

$ErrorActionPreference = 'SilentlyContinue'
$null = chcp 65001
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

function Get-IPUInt([string]$ip) {
    $b = [System.Net.IPAddress]::Parse($ip).GetAddressBytes()
    return [uint32](([int64]$b[0] -shl 24) -bor ([int64]$b[1] -shl 16) -bor ([int64]$b[2] -shl 8) -bor ([int64]$b[3]))
}

function Get-IPString([int64]$u) {
    return ('{0}.{1}.{2}.{3}' -f (($u -shr 24) -band 0xFF), (($u -shr 16) -band 0xFF), (($u -shr 8) -band 0xFF), ($u -band 0xFF))
}

function Get-PrefixLength([int64]$maskU) {
    $len = 0
    for ($i = 31; $i -ge 0; $i--) {
        if ((($maskU -shr $i) -band 1) -eq 1) { $len++ } else { break }
    }
    return $len
}

function Get-ActiveIPv4List {
    # 返回全部候选网卡，每项 { Name, Address, PrefixLen, State }（仅已连接/up、非 loopback、非 linklocal）
    $result = New-Object System.Collections.Generic.List[object]
    try {
        $interfaces = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()
        foreach ($iface in $interfaces) {
            $up = ($iface.OperationalStatus -eq [System.Net.NetworkInformation.OperationalStatus]::Up)
            if (-not $up) { continue }
            $props = $iface.GetIPProperties()
            if (-not $props) { continue }
            foreach ($ua in $props.UnicastAddresses) {
                if ($ua.Address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { continue }
                $ip = $ua.Address.ToString()
                if ($ip -like '169.254.*' -or $ip -like '127.*') { continue }
                $prefix = $ua.PrefixLength
                if (-not $prefix -or $prefix -lt 1) { $prefix = 24 }
                $result.Add([pscustomobject]@{
                    Name      = $iface.Name
                    Address   = $ip
                    PrefixLen = [int]$prefix
                    State     = $true
                })
            }
        }
    } catch { }
    if ($result.Count -gt 0) {
        return $result.ToArray()
    }

    # ipconfig 回退
    $out = (ipconfig | Out-String)
    $blocks = [regex]::Split($out, '\r?\n(?=\S)')
    foreach ($blk in $blocks) {
        $name = [regex]::Match($blk, '(?:以太网|Ethernet|无线局域网|Wireless|本地连接|adapter|适配器)[^\r\n]*').Value.Trim()
        if (-not $name) { $name = '?' }
        $m = [regex]::Match($blk, 'IPv4[^\r\n]*?(\d{1,3}(?:\.\d{1,3}){3})')
        if (-not $m.Success) { continue }
        $ip = $m.Groups[1].Value
        if ($ip -like '169.254.*' -or $ip -like '127.*') { continue }
        $prefix = 24
        $sm = [regex]::Match($blk, '(?:Subnet|サブネット|子网|掩码|Mask)[^\r\n]*?(\d{1,3}(?:\.\d{1,3}){3})')
        if ($sm.Success) {
            $prefix = Get-PrefixLength (Get-IPUInt $sm.Groups[1].Value)
        }
        $state = ($blk -notmatch '(?i)Media disconnected|媒体断开|メディア')
        $result.Add([pscustomobject]@{
            Name      = $name
            Address   = $ip
            PrefixLen = [int]$prefix
            State     = $state
        })
    }
    if ($result.Count -gt 0) {
        return $result.ToArray()
    }
    return $null
}

function Get-NicStateLabel([bool]$state) {
    if ($state) { return '已连接' }
    return '未连接'
}

function Resolve-Interface([string]$key, [object[]]$candidates) {
    if (-not $key) { return $null }
    $k = $key.Trim()
    foreach ($c in $candidates) {
        if ($c.Name -eq $k -or $c.Address -eq $k) { return $c }
    }
    return $null
}

function Show-NicMenu([object[]]$candidates) {
    if (-not $candidates -or $candidates.Count -eq 0) { return $null }
    while ($true) {
        Write-Host ('[输入] 请选择要检测的网卡 [1 - {0} / q 取消]:' -f $candidates.Count) -ForegroundColor Cyan
        for ($i = 0; $i -lt $candidates.Count; $i++) {
            Write-Host ('  {0,2}. {1,-12} {2}/{3}  [{4}]' -f ($i + 1), $candidates[$i].Name, $candidates[$i].Address, $candidates[$i].PrefixLen, (Get-NicStateLabel $candidates[$i].State))
        }
        Write-Host ''
        $choice = Read-Host ('[输入] 请输入选项数字 [1 - {0} / q 取消] 然后按回车' -f $candidates.Count)
        if ($choice -match '^[qQ]$') { return $null }
        $n = 0
        if ([int]::TryParse($choice, [ref]$n) -and $n -ge 1 -and $n -le $candidates.Count) {
            return $candidates[$n - 1]
        }
        Write-Host ('[错误] 无效输入，请输入 1 - {0} 或 q。' -f $candidates.Count) -ForegroundColor Red
        Write-Host ''
    }
}

function Get-ActiveIPv4 {
    # 返回首个候选 { Address, PrefixLen }，无法识别返回 $null
    $list = Get-ActiveIPv4List
    if ($list -and $list.Count -gt 0) {
        return $list[0]
    }
    return $null
}

function Get-SubnetHosts([string]$ip, [int]$prefix) {
    if ($prefix -lt 1 -or $prefix -gt 32) { return @() }
    $max32 = [int64]4294967295
    $maskU = ([int64]$max32 -shl (32 - $prefix)) -band $max32
    $ipU = Get-IPUInt $ip
    $network = ($ipU -band $maskU) -band $max32
    $invMask = ([int64]$max32 -bxor $maskU) -band $max32
    $broadcast = ($network -bor $invMask) -band $max32
    $total = $broadcast - $network - 1
    if ($total -lt 1 -or $total -gt 65534) { return @() }
    $hosts = New-Object System.Collections.Generic.List[string]
    for ($u = $network + 1; $u -lt $broadcast; $u++) {
        $hosts.Add((Get-IPString $u))
    }
    return $hosts.ToArray()
}

function Ping-Sweep([string[]]$hosts) {
    $alive = New-Object System.Collections.Generic.List[string]
    $batchSize = 128
    $totalBatches = [Math]::Ceiling($hosts.Count / [double]$batchSize)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $batchIndex = 0
    for ($i = 0; $i -lt $hosts.Count; $i += $batchSize) {
        $batchIndex++
        $n = [Math]::Min($i + $batchSize, $hosts.Count)
        $batch = $hosts[$i..($n - 1)]
        $tasks = New-Object System.Collections.Generic.List[object]
        $pings = New-Object System.Collections.Generic.List[object]
        for ($j = 0; $j -lt $batch.Count; $j++) {
            try {
                $p = New-Object System.Net.NetworkInformation.Ping
                $pings.Add($p)
                $tasks.Add($p.SendPingAsync($batch[$j], $PingTimeoutMs))
            } catch {
                $tasks.Add($null)
                $pings.Add($null)
            }
        }
        $validTasks = @($tasks | Where-Object { $_ })
        if ($validTasks.Count -gt 0) {
            try {
                [void][System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]($validTasks), $PingTimeoutMs)
            } catch { }
        }
        for ($j = 0; $j -lt $batch.Count; $j++) {
            $t = $tasks[$j]
            if (-not $t) { continue }
            if ($t.IsCompleted -and -not $t.IsFaulted -and -not $t.IsCanceled -and $t.Result.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                $alive.Add($batch[$j])
            }
        }
        foreach ($p in $pings) { try { if ($p) { $p.Dispose() } } catch { } }
        Write-Host ('  Ping 批次 {0}/{1}，已用 {2}s' -f $batchIndex, $totalBatches, [Math]::Round($sw.Elapsed.TotalSeconds, 1)) -ForegroundColor DarkGray
    }
    return $alive.ToArray()
}

function Test-TcpPorts([string[]]$ips, [int[]]$ports, [int]$timeoutMs) {
    $results = New-Object System.Collections.Generic.List[object]
    $pairs = foreach ($h in $ips) {
        foreach ($p in $ports) { [pscustomobject]@{ IP = $h; Port = $p } }
    }
    $batchSize = 128
    $totalBatches = [Math]::Ceiling($pairs.Count / [double]$batchSize)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $batchIndex = 0
    for ($i = 0; $i -lt $pairs.Count; $i += $batchSize) {
        $batchIndex++
        $n = [Math]::Min($i + $batchSize, $pairs.Count)
        $batch = $pairs[$i..($n - 1)]
        $tasks = New-Object System.Collections.Generic.List[object]
        $clients = New-Object System.Collections.Generic.List[object]
        for ($j = 0; $j -lt $batch.Count; $j++) {
            try {
                $c = New-Object System.Net.Sockets.TcpClient
                $clients.Add($c)
                $tasks.Add($c.ConnectAsync($batch[$j].IP, $batch[$j].Port))
            } catch {
                $tasks.Add($null)
                $clients.Add($null)
            }
        }
        $validTasks = @($tasks | Where-Object { $_ })
        if ($validTasks.Count -gt 0) {
            try {
                [void][System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]($validTasks), $timeoutMs)
            } catch { }
        }
        for ($j = 0; $j -lt $batch.Count; $j++) {
            $t = $tasks[$j]
            if ($t -and -not $t.IsFaulted -and -not $t.IsCanceled -and $t.IsCompleted -and $clients[$j] -and $clients[$j].Connected) {
                $results.Add($batch[$j])
            }
        }
        foreach ($c in $clients) { try { if ($c) { $c.Close() } } catch { } }
        Write-Host ('  端口批次 {0}/{1}，已用 {2}s' -f $batchIndex, $totalBatches, [Math]::Round($sw.Elapsed.TotalSeconds, 1)) -ForegroundColor DarkGray
    }
    return $results.ToArray()
}

function Get-Ascii([byte[]]$raw) {
    if (-not $raw -or $raw.Length -eq 0) { return '' }
    return [System.Text.Encoding]::ASCII.GetString($raw)
}

function Read-BytesTimeout($stream, [int]$timeoutMs, [int]$maxBytes = 4096) {
    try {
        $ms = New-Object System.IO.MemoryStream
        $buf = New-Object byte[] 1024
        $got = $false
        $deadline = [DateTime]::UtcNow.AddMilliseconds($timeoutMs)
        while ([DateTime]::UtcNow -lt $deadline -and $ms.Length -lt $maxBytes) {
            $iar = $stream.BeginRead($buf, 0, $buf.Length, $null, $null)
            $remaining = [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds
            if ($remaining -lt 0) { break }
            if (-not $iar.AsyncWaitHandle.WaitOne($remaining)) { break }
            if (-not $iar.IsCompleted) { break }
            $n = $stream.EndRead($iar)
            if ($n -le 0) { break }
            $ms.Write($buf, 0, $n)
            if (-not $got) {
                $got = $true
                $deadline = [DateTime]::UtcNow.AddMilliseconds([Math]::Min(200, $timeoutMs))
            }
        }
        return $ms.ToArray()
    } catch { return @() }
}

function Test-HttpLike([string]$ip, [int]$port, [int]$timeoutMs, [bool]$useTls) {
    $c = New-Object System.Net.Sockets.TcpClient
    $ssl = $null
    try {
        $connected = $c.ConnectAsync($ip, $port).Wait($timeoutMs)
        if (-not ($connected -and $c.Connected)) { return $null }
        $s = $c.GetStream()
        $stream = $s
        if ($useTls) {
            $ssl = New-Object System.Net.Security.SslStream($s, $false, { param($a, $b, $cc, $e) $true })
            $ssl.AuthenticateAsClient($ip, $null, [System.Security.Authentication.SslProtocols]::Tls12, $false)
            $stream = $ssl
        }
        $req = "GET / HTTP/1.0`r`nHost: {0}`r`nUser-Agent: Device-Scanner`r`nConnection: close`r`n`r`n" -f $ip
        $bytes = [System.Text.Encoding]::ASCII.GetBytes($req)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
        $raw = Read-BytesTimeout $stream $timeoutMs
        if ($raw.Length -eq 0) { return $null }
        $resp = Get-Ascii $raw
        if ($resp -match '(?im)^HTTP/\d\.\d\s+(\d+)') {
            $code = [int]$Matches[1]
            $server = ''
            if ($resp -match '(?im)^Server:\s*(.+)$') { $server = $Matches[1].Trim() }
            return [pscustomobject]@{ Valid = $true; Code = $code; Server = $server }
        }
    } catch { }
    finally {
        if ($ssl) { try { $ssl.Dispose() } catch { } }
        try { $c.Close() } catch { }
    }
    return $null
}

function Test-Ssh([string]$ip, [int]$port, [int]$timeoutMs) {
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $connected = $c.ConnectAsync($ip, $port).Wait($timeoutMs)
        if (-not ($connected -and $c.Connected)) { return $null }
        $s = $c.GetStream()
        $raw = Read-BytesTimeout $s $timeoutMs
        if ($raw.Length -eq 0) { return $null }
        $banner = Get-Ascii $raw
        if ($banner -match '(?m)^SSH-\d\.\d') {
            $first = (($banner -split "`r?`n") | Where-Object { $_ -ne '' } | Select-Object -First 1)
            return [pscustomobject]@{ Valid = $true; Code = 0; Server = $first.Trim() }
        }
    } catch { }
    finally { try { $c.Close() } catch { } }
    return $null
}

function Test-Banner220([string]$ip, [int]$port, [int]$timeoutMs) {
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $connected = $c.ConnectAsync($ip, $port).Wait($timeoutMs)
        if (-not ($connected -and $c.Connected)) { return $null }
        $s = $c.GetStream()
        $raw = Read-BytesTimeout $s $timeoutMs
        if ($raw.Length -eq 0) { return $null }
        $first = (($(Get-Ascii $raw) -split "`r?`n") | Where-Object { $_ -ne '' } | Select-Object -First 1)
        if (-not $first) { return $null }
        if ($first -match '^220[\s-]') {
            return [pscustomobject]@{ Valid = $true; Code = 0; Server = $first.Trim() }
        }
    } catch { }
    finally { try { $c.Close() } catch { } }
    return $null
}

function Test-Rtsp([string]$ip, [int]$port, [int]$timeoutMs) {
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $connected = $c.ConnectAsync($ip, $port).Wait($timeoutMs)
        if (-not ($connected -and $c.Connected)) { return $null }
        $s = $c.GetStream()
        $req = "OPTIONS rtsp://{0}:{1}/ RTSP/1.0`r`nCSeq: 1`r`nUser-Agent: Device-Scanner`r`n`r`n" -f $ip, $port
        $bytes = [System.Text.Encoding]::ASCII.GetBytes($req)
        $s.Write($bytes, 0, $bytes.Length)
        $s.Flush()
        $raw = Read-BytesTimeout $s $timeoutMs
        if ($raw.Length -eq 0) { return $null }
        $resp = Get-Ascii $raw
        if ($resp -match '(?im)^RTSP/1\.0\s+(\d+)') {
            $code = [int]$Matches[1]
            $server = ''
            if ($resp -match '(?im)^Server:\s*(.+)$') { $server = $Matches[1].Trim() }
            return [pscustomobject]@{ Valid = $true; Code = $code; Server = $server }
        }
    } catch { }
    finally { try { $c.Close() } catch { } }
    return $null
}

function Test-Telnet([string]$ip, [int]$port, [int]$timeoutMs) {
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $connected = $c.ConnectAsync($ip, $port).Wait($timeoutMs)
        if (-not ($connected -and $c.Connected)) { return $null }
        $s = $c.GetStream()
        $raw = Read-BytesTimeout $s $timeoutMs
        if ($raw.Length -eq 0) { return $null }
        $sb = New-Object System.Text.StringBuilder
        foreach ($b in $raw) {
            if (($b -ge 32 -and $b -lt 127) -or $b -eq 9) { [void]$sb.Append([char]$b) }
            elseif ($b -eq 10 -or $b -eq 13) { [void]$sb.Append(' ') }
        }
        $text = ($sb.ToString() -replace '\s+', ' ').Trim()
        if ($text.Length -eq 0) { $text = 'Telnet' }
        return [pscustomobject]@{ Valid = $true; Code = 0; Server = $text }
    } catch { }
    finally { try { $c.Close() } catch { } }
    return $null
}

function Test-Rdp([string]$ip, [int]$port, [int]$timeoutMs) {
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $connected = $c.ConnectAsync($ip, $port).Wait($timeoutMs)
        if (-not ($connected -and $c.Connected)) { return $null }
        $s = $c.GetStream()
        $req = [byte[]]@(0x03, 0x00, 0x00, 0x13, 0x0e, 0xe0, 0x00, 0x00, 0x00, 0x01, 0x00, 0x08, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00)
        $s.Write($req, 0, $req.Length)
        $s.Flush()
        $raw = Read-BytesTimeout $s $timeoutMs
        if ($raw.Length -lt 4) { return $null }
        if ($raw[0] -eq 0x03 -and $raw[1] -eq 0x00) {
            return [pscustomobject]@{ Valid = $true; Code = 0; Server = 'RDP' }
        }
    } catch { }
    finally { try { $c.Close() } catch { } }
    return $null
}

function New-Smb2NegotiateRequest {
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    $bw.Write([byte]0x00); $bw.Write([byte]0x00); $bw.Write([byte]0x00); $bw.Write([byte]0x68)
    $bw.Write([byte]0xFE); $bw.Write([byte]0x53); $bw.Write([byte]0x4D); $bw.Write([byte]0x42)
    $bw.Write([UInt16]0x0040)
    $bw.Write([UInt16]0)
    $bw.Write([UInt32]0)
    $bw.Write([UInt16]0)
    $bw.Write([UInt16]1)
    $bw.Write([UInt32]0)
    $bw.Write([UInt32]0)
    $bw.Write([Int64]1)
    $bw.Write([UInt32]0)
    $bw.Write([UInt32]0)
    $bw.Write([Int64]0)
    $bw.Write((New-Object byte[] 16))
    $bw.Write([UInt16]36)
    $bw.Write([UInt16]2)
    $bw.Write([UInt16]1)
    $bw.Write([UInt16]0)
    $bw.Write([UInt32]0)
    $bw.Write((New-Object byte[] 16))
    $bw.Write([UInt32]0)
    $bw.Write([UInt16]0)
    $bw.Write([UInt16]0)
    $bw.Write([UInt16]0x0202)
    $bw.Write([UInt16]0x0210)
    $bw.Flush()
    $data = $ms.ToArray()
    $bw.Dispose(); $ms.Dispose()
    return $data
}

function Test-Smb([string]$ip, [int]$port, [int]$timeoutMs) {
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $connected = $c.ConnectAsync($ip, $port).Wait($timeoutMs)
        if (-not ($connected -and $c.Connected)) { return $null }
        $s = $c.GetStream()
        $req = New-Smb2NegotiateRequest
        $s.Write($req, 0, $req.Length)
        $s.Flush()
        $raw = Read-BytesTimeout $s $timeoutMs 4096
        if ($raw.Length -lt 20) { return $null }
        if ($raw[4] -eq 0xFE -and $raw[5] -eq 0x53 -and $raw[6] -eq 0x4D -and $raw[7] -eq 0x42) {
            $dialect = ''
            if ($raw.Length -ge 74) {
                $d = [BitConverter]::ToUInt16($raw, 72)
                $dialect = 'SMB 0x{0:X4}' -f $d
            }
            return [pscustomobject]@{ Valid = $true; Code = 0; Server = $dialect }
        }
    } catch { }
    finally { try { $c.Close() } catch { } }
    return $null
}

function Test-Sip([string]$ip, [int]$port, [int]$timeoutMs) {
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $connected = $c.ConnectAsync($ip, $port).Wait($timeoutMs)
        if (-not ($connected -and $c.Connected)) { return $null }
        $s = $c.GetStream()
        $req = "OPTIONS sip:scanner@{0} SIP/2.0`r`nVia: SIP/2.0/TCP 192.0.2.1:5060;branch=z9hG4bK7766`r`nMax-Forwards: 70`r`nTo: <sip:scanner@{0}>`r`nFrom: <sip:scanner@{0}>;tag=8877`r`nCall-ID: 1a2b3c@{0}`r`nCSeq: 1 OPTIONS`r`nContent-Length: 0`r`n`r`n" -f $ip
        $bytes = [System.Text.Encoding]::ASCII.GetBytes($req)
        $s.Write($bytes, 0, $bytes.Length)
        $s.Flush()
        $raw = Read-BytesTimeout $s $timeoutMs
        if ($raw.Length -eq 0) { return $null }
        $resp = Get-Ascii $raw
        if ($resp -match '(?im)^SIP/2\.0\s+(\d+)') {
            $code = [int]$Matches[1]
            $server = ''
            if ($resp -match '(?im)^Server:\s*(.+)$') { $server = $Matches[1].Trim() }
            return [pscustomobject]@{ Valid = $true; Code = $code; Server = $server }
        }
    } catch { }
    finally { try { $c.Close() } catch { } }
    return $null
}

function Test-Mqtt([string]$ip, [int]$port, [int]$timeoutMs) {
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $connected = $c.ConnectAsync($ip, $port).Wait($timeoutMs)
        if (-not ($connected -and $c.Connected)) { return $null }
        $s = $c.GetStream()
        $req = [byte[]]@(0x10, 0x0C, 0x00, 0x04, 0x4D, 0x51, 0x54, 0x54, 0x04, 0x02, 0x00, 0x3C, 0x00, 0x00)
        $s.Write($req, 0, $req.Length)
        $s.Flush()
        $raw = Read-BytesTimeout $s $timeoutMs
        if ($raw.Length -lt 4) { return $null }
        if ($raw[0] -eq 0x20 -and $raw[3] -eq 0x00) {
            return [pscustomobject]@{ Valid = $true; Code = 0; Server = 'MQTT' }
        }
    } catch { }
    finally { try { $c.Close() } catch { } }
    return $null
}

function Test-Redis([string]$ip, [int]$port, [int]$timeoutMs) {
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $connected = $c.ConnectAsync($ip, $port).Wait($timeoutMs)
        if (-not ($connected -and $c.Connected)) { return $null }
        $s = $c.GetStream()
        $req = [System.Text.Encoding]::ASCII.GetBytes("PING`r`n")
        $s.Write($req, 0, $req.Length)
        $s.Flush()
        $raw = Read-BytesTimeout $s $timeoutMs
        if ($raw.Length -eq 0) { return $null }
        if ((Get-Ascii $raw) -match '^\+PONG') {
            return [pscustomobject]@{ Valid = $true; Code = 0; Server = 'Redis' }
        }
    } catch { }
    finally { try { $c.Close() } catch { } }
    return $null
}

function Get-Mac([string]$ip) {
    try {
        $n = Get-NetNeighbor -IPAddress $ip -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($n -and $n.LinkLayerAddress -and $n.LinkLayerAddress -notmatch '^0+(-|:|$)' -and $n.LinkLayerAddress -ne 'ff-ff-ff-ff-ff-ff') {
            return $n.LinkLayerAddress.ToUpper()
        }
    } catch { }
    try {
        $arp = & arp -a $ip 2>$null
        $re = '\b' + [regex]::Escape($ip) + '\b\s+([0-9a-fA-F]{2}[-:][0-9a-fA-F]{2}[-:][0-9a-fA-F]{2}[-:][0-9a-fA-F]{2}[-:][0-9a-fA-F]{2}[-:][0-9a-fA-F]{2})'
        foreach ($line in $arp) {
            if ($line -match $re) {
                return $Matches[1].Replace(':', '-').ToUpper()
            }
        }
    } catch { }
    return 'N/A'
}

# ===== 协议注册表 =====
$script:ProtocolTable = @(
    [pscustomobject]@{ Name = 'HTTP';   Ports = @(80);        Verify = { param($ip, $pt, $tm) Test-HttpLike $ip $pt $tm $false } }
    [pscustomobject]@{ Name = 'HTTPS';  Ports = @(443);       Verify = { param($ip, $pt, $tm) Test-HttpLike $ip $pt $tm $true } }
    [pscustomobject]@{ Name = 'SSH';    Ports = @(22);        Verify = { param($ip, $pt, $tm) Test-Ssh $ip $pt $tm } }
    [pscustomobject]@{ Name = 'FTP';    Ports = @(21);        Verify = { param($ip, $pt, $tm) Test-Banner220 $ip $pt $tm } }
    [pscustomobject]@{ Name = 'SMTP';   Ports = @(25);        Verify = { param($ip, $pt, $tm) Test-Banner220 $ip $pt $tm } }
    [pscustomobject]@{ Name = 'RTSP';   Ports = @(554, 8554); Verify = { param($ip, $pt, $tm) Test-Rtsp $ip $pt $tm } }
    [pscustomobject]@{ Name = 'Telnet'; Ports = @(23);        Verify = { param($ip, $pt, $tm) Test-Telnet $ip $pt $tm } }
    [pscustomobject]@{ Name = 'RDP';    Ports = @(3389);      Verify = { param($ip, $pt, $tm) Test-Rdp $ip $pt $tm } }
    [pscustomobject]@{ Name = 'SMB';    Ports = @(445);       Verify = { param($ip, $pt, $tm) Test-Smb $ip $pt $tm } }
    [pscustomobject]@{ Name = 'SIP';    Ports = @(5060);      Verify = { param($ip, $pt, $tm) Test-Sip $ip $pt $tm } }
    [pscustomobject]@{ Name = 'MQTT';   Ports = @(1883);      Verify = { param($ip, $pt, $tm) Test-Mqtt $ip $pt $tm } }
    [pscustomobject]@{ Name = 'Redis';  Ports = @(6379);      Verify = { param($ip, $pt, $tm) Test-Redis $ip $pt $tm } }
)

function Get-SelectedProtocol([string]$name) {
    if (-not $name) { return $null }
    $t = $name.Trim().ToUpper()
    return @($script:ProtocolTable | Where-Object { $_.Name -eq $t } | Select-Object -First 1)
}

function Show-ProtocolMenu([object[]]$registry) {
    while ($true) {
        Write-Host '[输入] 请选择要检测的协议（每次只能选择 1 种）：' -ForegroundColor Cyan
        for ($i = 0; $i -lt $registry.Count; $i++) {
            Write-Host ('  {0,2}. {1,-8} 端口: {2}' -f ($i + 1), $registry[$i].Name, ($registry[$i].Ports -join ','))
        }
        Write-Host ''
        $choice = Read-Host ('[输入] 请输入选项数字 [1 - {0} / q 取消] 然后按回车' -f $registry.Count)
        if ($choice -match '^[qQ]$') { return $null }
        $n = 0
        if ([int]::TryParse($choice, [ref]$n) -and $n -ge 1 -and $n -le $registry.Count) {
            return $registry[$n - 1]
        }
        Write-Host ('[错误] 无效输入，请输入 1 - {0} 或 q。' -f $registry.Count) -ForegroundColor Red
        Write-Host ''
    }
}

# ===== 主流程 =====
Write-Host '========================================='
Write-Host '  设备协议检测工具'
Write-Host '  版本 1.2'
Write-Host '========================================='
Write-Host '[适用场景]'
Write-Host '需要识别局域网内设备开放的端口与协议服务（HTTP、SSH、FTP、RTSP、RDP 等）时使用。'
Write-Host ''
Write-Host '[功能说明]'
Write-Host '自动识别本机网卡（多网卡时可选择需要检测的网卡），扫描存活主机，并按所选协议做端口检测与握手复核，输出每台设备的 IP、MAC 与服务信息。'
Write-Host ''
Write-Host '[操作方式]'
Write-Host '输入选项数字选择 1 种协议后按回车，输入 q 取消；多网卡时需再选择检测网卡；随后确认扫描参数后自动执行。'
Write-Host ''
Write-Host '[执行步骤]'
Write-Host '1. 识别网卡与待扫描主机'
Write-Host '2. Ping 扫描存活主机'
Write-Host '3. 检测开放端口'
Write-Host '4. 协议握手复核'
Write-Host ''
Write-Host '[注意事项]'
Write-Host '- 每次运行仅检测 1 种协议；可用 -Ports 附加原始端口（仅做 TCP 开放检测）。'
Write-Host '- 多网卡环境可用 -Interface <接口名或IP> 指定网卡，或用 -Subnet 直接指定网段。'
Write-Host '- 扫描整个网段耗时较长，请耐心等待。'
Write-Host '- 需在可访问目标网段的网络环境下运行。'
Write-Host '========================================='

$swTotal = [System.Diagnostics.Stopwatch]::StartNew()

# ---- 收集参数：协议 ----
$selectedProtocol = Get-SelectedProtocol -name $Protocol
if (-not $selectedProtocol -and $Protocol) {
    Write-Host ''
    Write-Host ('[错误] 未知协议: {0}（可用: {1}）。' -f $Protocol, ($script:ProtocolTable.Name -join ', ')) -ForegroundColor Red
}
if (-not $selectedProtocol) {
    Write-Host ''
    $selectedProtocol = Show-ProtocolMenu $script:ProtocolTable
    if (-not $selectedProtocol) {
        Write-Host '[提示] 已取消，未开始扫描。'
        Write-Host ''
        Read-Host '[结束] 按回车键退出...'
        exit 0
    }
}

$extraPorts = @($Ports)

# ---- 收集参数：网段 / 网卡 ----
$localIP = ''
$prefix = 0
$nicName = ''
if ($Subnet) {
    $m = [regex]::Match($Subnet, '^(\d{1,3}(?:\.\d{1,3}){3})/(\d{1,2})$')
    if (-not $m.Success) {
        Write-Host ''
        Write-Host '[错误] Subnet 格式错误，应为 CIDR 格式，例如 192.168.1.0/24。' -ForegroundColor Red
        Write-Host '[提示] 已取消，未开始扫描。'
        Write-Host ''
        Read-Host '[结束] 按回车键退出...'
        exit 0
    }
    $localIP = $m.Groups[1].Value
    $prefix = [int]$m.Groups[2].Value
}
else {
    $candidates = @(Get-ActiveIPv4List)
    if (-not $candidates -or $candidates.Count -eq 0) {
        Write-Host ''
        Write-Host '[错误] 无法自动识别网段，请使用 -Subnet 手动指定，例如 -Subnet 192.168.1.0/24。' -ForegroundColor Red
        Write-Host '[提示] 已取消，未开始扫描。'
        Write-Host ''
        Read-Host '[结束] 按回车键退出...'
        exit 0
    }
    $chosen = $null
    if ($Interface) {
        $chosen = Resolve-Interface $Interface $candidates
        if (-not $chosen) {
            Write-Host ''
            Write-Host ('[错误] 未找到匹配的网卡: {0}（接口名或 IP）。' -f $Interface) -ForegroundColor Red
            Write-Host ('[提示] 可用网卡：{0}。' -f (($candidates | ForEach-Object { '{0} ({1})' -f $_.Name, $_.Address }) -join ', '))
            Write-Host '[提示] 已取消，未开始扫描。'
            Write-Host ''
            Read-Host '[结束] 按回车键退出...'
            exit 0
        }
    }
    elseif ($Host.UI.RawUI -and $Host.Name -notmatch 'NonInteractive|Pipeline') {
        Write-Host ''
        $chosen = Show-NicMenu $candidates
        if (-not $chosen) {
            Write-Host '[提示] 已取消，未开始扫描。'
            Write-Host ''
            Read-Host '[结束] 按回车键退出...'
            exit 0
        }
    }
    else {
        $chosen = $candidates[0]
    }
    $localIP = $chosen.Address
    $prefix = $chosen.PrefixLen
    $nicName = $chosen.Name
}

$scanPorts = New-Object System.Collections.Generic.List[int]
foreach ($pp in $selectedProtocol.Ports) { $scanPorts.Add([int]$pp) }
foreach ($pp in $extraPorts) { $scanPorts.Add([int]$pp) }
$scanPorts = @($scanPorts | Sort-Object -Unique)

# ---- 参数回显确认 ----
Write-Host ''
Write-Host '[提示] 扫描参数确认：'
Write-Host ('  检测协议: {0}（端口: {1}）' -f $selectedProtocol.Name, ($selectedProtocol.Ports -join ','))
if ($nicName) { Write-Host ('  检测网卡: {0}' -f $nicName) }
Write-Host ('  扫描网段: {0}/{1}' -f $localIP, $prefix)
Write-Host ('  检测端口: {0}' -f ($scanPorts -join ','))
if ($extraPorts.Count -gt 0) { Write-Host ('  附加原始端口: {0}' -f ($extraPorts -join ',')) }
Write-Host ('  TCP 超时: {0}ms，Ping 超时: {1}ms' -f $TimeoutMs, $PingTimeoutMs)
while ($true) {
    $ok = Read-Host '[输入] 确认开始扫描？[y 开始 / q 取消]'
    if ($ok -match '^[yY]$') { break }
    if ($ok -match '^[qQ]$') {
        Write-Host '[提示] 已取消，未开始扫描。'
        Write-Host ''
        Read-Host '[结束] 按回车键退出...'
        exit 0
    }
    Write-Host '[错误] 无效输入，请输入 y 或 q。'
}

# ---- 步骤 1/4：识别网卡与待扫描主机 ----
Write-Host ''
Write-Host '[进度] 步骤 1/4：识别网卡与待扫描主机 ...'
$hosts = Get-SubnetHosts $localIP $prefix
$selfU = Get-IPUInt $localIP
$hosts = @($hosts | Where-Object { (Get-IPUInt $_) -ne $selfU })
Write-Host ('[完成] 扫描网段 {0}/{1}，待扫描主机 {2} 台（已排除本机）。' -f $localIP, $prefix, $hosts.Count)

# ---- 步骤 2/4：Ping 扫描存活主机 ----
$alive = @()
if ($hosts.Count -gt 0) {
    Write-Host ''
    Write-Host '[进度] 步骤 2/4：Ping 扫描存活主机 ...'
    $alive = @(Ping-Sweep $hosts)
    Write-Host ('[完成] 存活主机 {0} 台。' -f $alive.Count)
}
else {
    Write-Host '[提示] 网段内无可扫描主机，扫描中止。'
}

# ---- 步骤 3/4：检测开放端口 ----
$openPairs = @()
if ($alive.Count -gt 0) {
    Write-Host ''
    Write-Host '[进度] 步骤 3/4：检测开放端口 ...'
    $openPairs = @(Test-TcpPorts $alive $scanPorts $TimeoutMs)
    Write-Host ('[完成] 开放端口对 {0} 个。' -f $openPairs.Count)
}
else {
    Write-Host '[提示] 未发现存活主机，跳过端口检测与协议复核。'
}

# ---- 步骤 4/4：协议握手复核 ----
$rowList = New-Object System.Collections.Generic.List[object]
if ($openPairs.Count -gt 0) {
    Write-Host ''
    Write-Host '[进度] 步骤 4/4：协议握手复核 ...'
    $count = 0
    $total = $openPairs.Count
    foreach ($pair in ($openPairs | Sort-Object IP, Port)) {
        $count++
        if ($count % 50 -eq 0 -or $count -eq $total) {
            Write-Host ('  复核进度 {0}/{1}' -f $count, $total) -ForegroundColor DarkGray
        }
        $matched = $false
        if ($selectedProtocol.Ports -contains $pair.Port) {
            $info = & $selectedProtocol.Verify $pair.IP $pair.Port $TimeoutMs
            if ($info) {
                $matched = $true
                $obj = [pscustomobject]@{
                    Protocol = $selectedProtocol.Name
                    IP       = $pair.IP
                    MAC      = (Get-Mac $pair.IP)
                    Port     = $pair.Port
                    Code     = $info.Code
                    Server   = $info.Server
                }
                $rowList.Add($obj)
            }
        }
        if (-not $matched -and $extraPorts -contains $pair.Port) {
            $obj = [pscustomobject]@{
                Protocol = 'TCP'
                IP       = $pair.IP
                MAC      = (Get-Mac $pair.IP)
                Port     = $pair.Port
                Code     = 0
                Server   = '(port open)'
            }
            $rowList.Add($obj)
        }
    }
    Write-Host '[完成] 协议握手复核完成。'
}
elseif ($alive.Count -gt 0) {
    Write-Host '[提示] 未发现开放端口，跳过协议复核。'
}

# ---- 结果汇总 ----
$totalDevices = @($rowList | Select-Object -ExpandProperty IP -Unique).Count
if ($rowList.Count -gt 0) {
    $names = @($rowList | Select-Object -ExpandProperty Protocol -Unique | Sort-Object)
    foreach ($name in $names) {
        $rows = @($rowList | Where-Object { $_.Protocol -eq $name })
        $ips = @($rows | Select-Object -ExpandProperty IP -Unique)
        Write-Host ''
        Write-Host ('=== {0} 设备 ({1}) ===' -f $name, $ips.Count) -ForegroundColor Green
        $rows | Select-Object IP, MAC, Port, Code, Server | Sort-Object IP, Port | Format-Table -AutoSize | Out-Host
    }
    Write-Host ('[结果] 发现设备总数: {0} 台。' -f $totalDevices) -ForegroundColor Green
    if ($OutFile) {
        $rowList | Sort-Object Protocol, IP, Port | Export-Csv -Path $OutFile -NoTypeInformation -Encoding UTF8
        Write-Host ('[完成] 结果已导出: {0}' -f $OutFile) -ForegroundColor Green
    }
}
else {
    Write-Host '[提示] 有端口开放，但未通过任何协议复核。' -ForegroundColor Yellow
}

Write-Host ''
Write-Host '[结果] 扫描完成。'
Write-Host ('  检测协议: {0}' -f $selectedProtocol.Name)
Write-Host ('  扫描网段: {0}/{1}' -f $localIP, $prefix)
Write-Host ('  存活主机: {0}' -f $alive.Count)
Write-Host ('  开放端口对: {0}' -f $openPairs.Count)
Write-Host ('  识别设备: {0} 台' -f $totalDevices)
Write-Host ('  共耗时: {0}s' -f [Math]::Round($swTotal.Elapsed.TotalSeconds, 1))
Write-Host ''
Write-Host '扫描结束。' -ForegroundColor Cyan
Write-Host ''
Read-Host '[结束] 按回车键退出...'
exit 0
