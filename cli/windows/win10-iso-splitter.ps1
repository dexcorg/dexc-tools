# Windows 10 ISO 分割与重打包工具（PowerShell · UTF-8 无 BOM）
$null = chcp 65001
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Continue'
$fail = 0
$failSteps = @()

$sep = '=' * 50
Write-Host $sep
Write-Host '       Windows 10 ISO 分割与重打包工具'
Write-Host '       版本 1.0'
Write-Host $sep
Write-Host '[适用场景]'
Write-Host 'Windows 10 原始镜像内包含超过 4GB 的 install.wim/install.esd 文件，'
Write-Host '无法直接写入 FAT32 格式的 U 盘时使用。'
Write-Host ''
Write-Host '[功能说明]'
Write-Host '挂载原始 ISO，将超大镜像文件分割为小于 FAT32 上限的多个分片，'
Write-Host '然后重新打包为可引导的 ISO 文件，确保可写入 FAT32 分区。'
Write-Host ''
Write-Host '[操作方式]'
Write-Host '按提示依次输入：源 ISO 路径、分割大小、oscdimg 路径，'
Write-Host '支持直接拖拽文件到终端窗口。'
Write-Host ''
Write-Host '[执行步骤]'
Write-Host '1. 创建临时工作目录'
Write-Host '2. 挂载 ISO 并复制全部文件'
Write-Host '3. 分割 WIM/ESD 镜像文件'
Write-Host '4. 验证启动文件完整性'
Write-Host '5. 调用 oscdimg 重新打包可启动 ISO'
Write-Host ''
Write-Host '[注意事项]'
Write-Host '- 需要管理员权限才能挂载 ISO 和执行 DISM 操作。'
Write-Host '- 需要安装 Windows ADK 中的 oscdimg.exe 才能完成重打包。'
Write-Host '- 执行过程会占用约 2 倍 ISO 大小的磁盘空间，请确保空间充足。'
Write-Host '- 分割完成后会自动删除临时文件。'
Write-Host $sep

# ---- 管理员权限检查 ----
try {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch {
    $isAdmin = $false
}
if (-not $isAdmin) {
    Write-Host ''
    Write-Host '[提示] 未检测到管理员权限，挂载 ISO 和 DISM 操作可能失败。'
    Write-Host '       建议关闭后右键以管理员权限运行。'
    $ok = Read-Host '[输入] 是否仍要继续？[y 继续 / n 取消]'
    if ($ok -notmatch '^[yY]$') { Write-Host '[提示] 已取消。'; Read-Host '[结束] 按回车键退出...'; exit 0 }
    Write-Host ''
}

# ---- 参数 1/3：源 ISO 文件路径 ----
$sourceISO = ''
while ($true) {
    Write-Host '[输入] (参数 1/3) 请拖入原始 Windows ISO 文件，然后按回车:'
    $raw = Read-Host '[输入]'
    $sourceISO = $raw.Trim('"').TrimEnd('\')
    if ($sourceISO -eq '') {
        Write-Host '[错误] 路径不能为空，请重新输入。'
        continue
    }
    if (Test-Path -LiteralPath $sourceISO) { break }
    Write-Host "[错误] 文件不存在: $sourceISO"
}
Write-Host "[完成] 源 ISO: $sourceISO"
Write-Host ''

# ---- 参数 2/3：分割大小 ----
$defaultSize = 3800
$splitSize = 0
while ($true) {
    Write-Host "[输入] (参数 2/3) 分割大小（MB），范围 100-4000，[回车使用默认值: $defaultSize]:"
    $raw = Read-Host '[输入]'
    if ($raw -eq '') {
        $splitSize = $defaultSize
        break
    }
    $parsed = 0
    if ([int]::TryParse($raw, [ref]$parsed) -and $parsed -ge 100 -and $parsed -le 4000) {
        $splitSize = $parsed
        break
    }
    Write-Host '[错误] 输入无效，请输入 100-4000 的整数。'
}
Write-Host "[完成] 分割大小: ${splitSize} MB"
Write-Host ''

# ---- 参数 3/3：oscdimg.exe 路径 ----
$oscdimgCmd = ''

# 检测 1：系统 PATH
try {
    $cmd = Get-Command oscdimg -ErrorAction SilentlyContinue
    if ($cmd) { $oscdimgCmd = $cmd.Source }
} catch { }

# 检测 2：ADK 默认路径（Windows Kits 10）
if (-not $oscdimgCmd) {
    $p = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe'
    if (Test-Path $p) { $oscdimgCmd = $p }
}

# 检测 3：ADK 11 路径
if (-not $oscdimgCmd) {
    $p = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\11\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe'
    if (Test-Path $p) { $oscdimgCmd = $p }
}

# 检测 4：注册表读取 ADK 安装路径
if (-not $oscdimgCmd) {
    try {
        $regPath = Get-ItemProperty -Path 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots' -Name 'KitsRoot10' -ErrorAction SilentlyContinue
        if ($regPath -and $regPath.KitsRoot10) {
            $p = Join-Path $regPath.KitsRoot10 'Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe'
            if (Test-Path $p) { $oscdimgCmd = $p }
        }
    } catch { }
}

if ($oscdimgCmd) {
    Write-Host "[提示] 已自动检测到 oscdimg: $oscdimgCmd"
    $useAuto = Read-Host '[输入] 使用此路径？[y 使用 / n 手动指定]'
    if ($useAuto -notmatch '^[yY]$') { $oscdimgCmd = '' }
}

if (-not $oscdimgCmd) {
    while ($true) {
        Write-Host '[输入] (参数 3/3) 请拖入 oscdimg.exe 文件，然后按回车:'
        $raw = Read-Host '[输入]'
        $oscdimgCmd = $raw.Trim('"').TrimEnd('\')
        if ($oscdimgCmd -eq '') {
            Write-Host '[错误] 路径不能为空，请重新输入。'
            continue
        }
        if (Test-Path -LiteralPath $oscdimgCmd) { break }
        Write-Host "[错误] 文件不存在: $oscdimgCmd"
    }
}
Write-Host "[完成] oscdimg: $oscdimgCmd"
Write-Host ''

# ---- 输出路径计算 ----
$isoDir = Split-Path -Parent $sourceISO
$isoName = [IO.Path]::GetFileNameWithoutExtension($sourceISO)
$outputISO = Join-Path $isoDir "${isoName}_Split.iso"
$workDir = Join-Path $PSScriptRoot 'ISO_Working_Folder'

# ---- 回显确认 ----
Write-Host '========================================'
Write-Host '[提示] 请确认以下参数：'
Write-Host "  源 ISO 文件:   $sourceISO"
Write-Host "  分割大小:       ${splitSize} MB"
Write-Host "  oscdimg 路径:   $oscdimgCmd"
Write-Host "  输出文件:       $outputISO"
Write-Host "  临时工作目录:   $workDir"
Write-Host '========================================'
while ($true) {
    $ok = Read-Host '[输入] 确认开始执行？[y 开始 / q 取消]'
    if ($ok -match '^[yY]$') { break }
    if ($ok -match '^[qQ]$') { Write-Host '[提示] 已取消。'; Read-Host '[结束] 按回车键退出...'; exit 0 }
    Write-Host '[错误] 无效输入，请输入 y 或 q。'
}
Write-Host ''

# ---- 清理残留工作目录 ----
if (Test-Path $workDir) {
    Write-Host '[提示] 发现残留工作目录，正在清理...'
    Remove-Item -Path $workDir -Recurse -Force -ErrorAction SilentlyContinue
}

# ============================================================
# 步骤 1/5：创建临时工作目录
# ============================================================
Write-Host '[进度] 步骤 1/5：创建临时工作目录 ...'
try {
    if (-not (Test-Path $workDir)) {
        New-Item -Path $workDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
    }
    Write-Host '[完成] 工作目录已创建。'
} catch {
    $fail++
    $failSteps += "步骤 1/5 创建工作目录失败: $($_.Exception.Message)"
    Write-Host "[失败] $($_.Exception.Message)"
    Write-Host ''
    Write-Host '[结果] 执行中断。'
    Read-Host '[结束] 按回车键退出...'
    exit 1
}

# ============================================================
# 步骤 2/5：挂载 ISO 并复制文件
# ============================================================
Write-Host ''
Write-Host '[进度] 步骤 2/5：挂载 ISO 并复制文件（可能需要数分钟）...'
$driveLetter = ''
try {
    $img = Mount-DiskImage -ImagePath $sourceISO -PassThru -ErrorAction Stop
    $vol = Get-Volume -DiskImage $img -ErrorAction Stop | Where-Object { $_.DriveLetter } | Select-Object -First 1
    if (-not $vol -or -not $vol.DriveLetter) {
        throw '无法获取挂载卷的盘符。'
    }
    $driveLetter = $vol.DriveLetter
    Write-Host "[提示] ISO 已挂载至 ${driveLetter}:\"
    Write-Host '[进度] 正在复制文件到工作目录...'
    & xcopy "${driveLetter}:\*" "$workDir\" /s /e /h /y /q | Out-Null
    Write-Host '[完成] 文件复制完成。'
} catch {
    $fail++
    $failSteps += "步骤 2/5 挂载/复制 ISO 失败: $($_.Exception.Message)"
    Write-Host "[失败] $($_.Exception.Message)"
} finally {
    try {
        if ($img) { Dismount-DiskImage -ImagePath $sourceISO -ErrorAction SilentlyContinue | Out-Null }
    } catch { }
}

if ($driveLetter -eq '' -or -not (Test-Path "$workDir\sources" -ErrorAction SilentlyContinue)) {
    Write-Host '[失败] ISO 挂载或复制失败，无法继续。'
    Write-Host ''
    Write-Host '[结果] 执行中断。'
    Remove-Item -Path $workDir -Recurse -Force -ErrorAction SilentlyContinue
    Read-Host '[结束] 按回车键退出...'
    exit 1
}

# ============================================================
# 步骤 3/5：分割 WIM/ESD 镜像文件
# ============================================================
Write-Host ''
Write-Host '[进度] 步骤 3/5：分割 WIM/ESD 镜像文件 ...'
$targetImage = $null
if (Test-Path "$workDir\sources\install.wim") {
    $targetImage = "$workDir\sources\install.wim"
} elseif (Test-Path "$workDir\sources\install.esd") {
    $targetImage = "$workDir\sources\install.esd"
}

if (-not $targetImage) {
    $fail++
    $failSteps += '步骤 3/5 未找到 install.wim 或 install.esd'
    Write-Host '[失败] 未找到 install.wim 或 install.esd。'
} else {
    $fileName = Split-Path -Leaf $targetImage
    $fileSizeMB = [Math]::Round((Get-Item $targetImage).Length / 1MB, 1)
    Write-Host "[提示] 目标文件: $fileName ($fileSizeMB MB)"

    if ($fileSizeMB -le $splitSize) {
        Write-Host '[提示] 文件大小未超过分割阈值，无需分割，将直接使用原文件打包。'
    } else {
        try {
            $swmPath = "$workDir\sources\install.swm"
            dism /Split-Image /ImageFile:"$targetImage" /SWMFile:"$swmPath" /FileSize:$splitSize
            if ($LASTEXITCODE -ne 0) { throw "DISM 返回错误代码 $LASTEXITCODE" }
            Remove-Item -Path $targetImage -Force
            $partCount = (Get-ChildItem -Path "$workDir\sources" -Filter 'install*.swm').Count
            Write-Host "[完成] 镜像已分割为 $partCount 个分片（每个不超过 ${splitSize} MB）。"
        } catch {
            $fail++
            $failSteps += "步骤 3/5 分割镜像失败: $($_.Exception.Message)"
            Write-Host "[失败] $($_.Exception.Message)"
        }
    }
}

if ($fail -gt 0) {
    Write-Host ''
    Write-Host '[结果] 执行中断。'
    Remove-Item -Path $workDir -Recurse -Force -ErrorAction SilentlyContinue
    Read-Host '[结束] 按回车键退出...'
    exit 1
}

# ============================================================
# 步骤 4/5：验证启动文件完整性
# ============================================================
Write-Host ''
Write-Host '[进度] 步骤 4/5：验证启动文件完整性 ...'
$bootFile = Join-Path $workDir 'boot\etfsboot.com'
$efiFile = Join-Path $workDir 'efi\microsoft\boot\efisys.bin'

$missing = @()
if (-not (Test-Path $bootFile)) { $missing += 'boot\etfsboot.com (BIOS 引导)' }
if (-not (Test-Path $efiFile)) { $missing += 'efi\microsoft\boot\efisys.bin (UEFI 引导)' }

if ($missing.Count -gt 0) {
    $fail++
    $msg = '缺失启动文件: ' + ($missing -join ', ')
    $failSteps += "步骤 4/5 $msg"
    Write-Host "[失败] $msg"
} else {
    Write-Host '[完成] 启动文件验证通过（BIOS + UEFI）。'
}

if ($fail -gt 0) {
    Write-Host ''
    Write-Host '[结果] 执行中断。'
    Remove-Item -Path $workDir -Recurse -Force -ErrorAction SilentlyContinue
    Read-Host '[结束] 按回车键退出...'
    exit 1
}

# ============================================================
# 步骤 5/5：调用 oscdimg 重新打包可启动 ISO
# ============================================================
Write-Host ''
Write-Host '[进度] 步骤 5/5：调用 oscdimg 重新打包可启动 ISO（可能需要数分钟）...'
try {
    $bootData = "2#p0,e,b`"$bootFile`"#pEF,e,b`"$efiFile`""
    & "$oscdimgCmd" -m -o -u2 -udfver102 -bootdata:$bootData "$workDir" "$outputISO"
    if ($LASTEXITCODE -ne 0) { throw "oscdimg 返回错误代码 $LASTEXITCODE" }
    $outSizeMB = [Math]::Round((Get-Item $outputISO).Length / 1MB, 1)
    Write-Host "[完成] ISO 打包成功: $outputISO ($outSizeMB MB)"
} catch {
    $fail++
    $failSteps += "步骤 5/5 ISO 打包失败: $($_.Exception.Message)"
    Write-Host "[失败] $($_.Exception.Message)"
}

# ============================================================
# 清理临时工作目录
# ============================================================
Write-Host ''
Write-Host '[进度] 正在清理临时工作目录...'
try {
    Remove-Item -Path $workDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host '[完成] 临时文件已清理。'
} catch {
    Write-Host '[提示] 临时目录清理失败，请手动删除: ' + $workDir
}

# ============================================================
# 结果汇总
# ============================================================
Write-Host ''
Write-Host '========================================'
Write-Host '[结果] 执行完成。'
Write-Host "  成功：$([int](5 - $fail))/5"
Write-Host "  失败：$fail/5"
if ($failSteps.Count -gt 0) {
    foreach ($s in $failSteps) {
        Write-Host "  - $s"
    }
}
if ($fail -eq 0) {
    Write-Host "  输出文件：$outputISO"
    Write-Host "  分割大小：${splitSize} MB"
}
Write-Host '========================================'
Read-Host '[结束] 按回车键退出...'
exit 0
