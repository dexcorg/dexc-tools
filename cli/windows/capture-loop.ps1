<#
.SYNOPSIS
  定时截图工具（Windows / PowerShell 5.1 兼容）

.DESCRIPTION
  按设定间隔自动截取屏幕画面，文件循环覆盖保存。
  支持自定义保存目录、截图间隔和保留数量。

.PARAMETER SaveDir
  截图保存目录。缺省为脚本所在目录。

.PARAMETER Interval
  截图间隔（秒），默认 30。

.PARAMETER MaxCount
  最大保留数量（张），默认 10。

.EXAMPLE
  .\capture-loop.ps1
  .\capture-loop.ps1 -Interval 10 -MaxCount 20
  .\capture-loop.ps1 -SaveDir "D:\Screenshots" -Interval 60
#>

param(
    [string]$SaveDir,
    [int]$Interval = 30,
    [int]$MaxCount = 10
)

$ErrorActionPreference = 'SilentlyContinue'
$null = chcp 65001
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ---------- 路径规整函数 ----------
function Sanitize-Path {
    param([string]$InputPath)
    $InputPath = $InputPath.Trim('"')
    $InputPath = $InputPath.TrimEnd('\')
    return $InputPath
}

# ---------- 获取脚本所在目录 ----------
$ScriptDir = $PSScriptRoot
if (-not $ScriptDir) { $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition }
$DefaultSaveDir = $ScriptDir

# ---------- 启动说明 ----------
Write-Host '========================================='
Write-Host '  定时截图工具'
Write-Host '  版本 1.0'
Write-Host '========================================='
Write-Host '[适用场景]'
Write-Host '需要定期自动截取屏幕画面（如监控、录制操作过程、定时记录屏幕状态）时使用。'
Write-Host ''
Write-Host '[功能说明]'
Write-Host '按设定间隔自动截图，文件循环覆盖保存，支持自定义保存目录、截图间隔和保留数量。'
Write-Host ''
Write-Host '[操作方式]'
Write-Host '输入截图保存目录（可拖拽文件夹）、间隔秒数、保留数量，确认后自动执行。'
Write-Host '直接回车使用默认值。'
Write-Host ''
Write-Host '[执行步骤]'
Write-Host '1. 设置截图保存目录'
Write-Host '2. 设置截图间隔（秒）'
Write-Host '3. 设置最大保留数量'
Write-Host '4. 确认参数后开始循环截图'
Write-Host ''
Write-Host '[注意事项]'
Write-Host '- 首次运行需授予屏幕截图权限。'
Write-Host '- 截图文件按序号循环覆盖，保留最近 N 张。'
Write-Host '- 按 Ctrl+C 可随时停止。'
Write-Host '========================================='

# ---------- 参数变量 ----------
$finalSaveDir = ''
$finalInterval = $Interval
$finalMaxCount = $MaxCount

# ---------- 收集参数（参数 1/3：保存目录） ----------
Write-Host ''
Write-Host '[进度] 步骤 1/3：设置截图保存目录 ...'
$rawDir = Read-Host "[输入] 请输入截图保存目录 [回车使用默认值: $DefaultSaveDir]"

if ([string]::IsNullOrWhiteSpace($rawDir)) {
    $finalSaveDir = $DefaultSaveDir
} else {
    $rawDir = Sanitize-Path $rawDir
    if (Test-Path $rawDir) {
        $finalSaveDir = (Resolve-Path $rawDir).Path
    } elseif (New-Item -ItemType Directory -Path $rawDir -Force -ErrorAction SilentlyContinue) {
        $finalSaveDir = (Resolve-Path $rawDir).Path
    } else {
        Write-Host '[错误] 目录无效或无法创建，使用默认目录'
        $finalSaveDir = $DefaultSaveDir
    }
}
Write-Host "[完成] 保存目录: $finalSaveDir"

# ---------- 收集参数（参数 2/3：截图间隔） ----------
Write-Host ''
Write-Host '[进度] 步骤 2/3：设置截图间隔 ...'
$rawInterval = Read-Host "[输入] 请输入截图间隔（秒）[回车使用默认值: $Interval]"

if ([string]::IsNullOrWhiteSpace($rawInterval)) {
    $finalInterval = $Interval
} elseif ($rawInterval -match '^\d+$' -and [int]$rawInterval -gt 0) {
    $finalInterval = [int]$rawInterval
} else {
    Write-Host "[错误] 输入无效，使用默认间隔 $Interval 秒"
    $finalInterval = $Interval
}
Write-Host "[完成] 截图间隔: $finalInterval 秒"

# ---------- 收集参数（参数 3/3：保留数量） ----------
Write-Host ''
Write-Host '[进度] 步骤 3/3：设置截图保留上限 ...'
$rawMax = Read-Host "[输入] 请输入截图保留上限（张）[回车使用默认值: $MaxCount]"

if ([string]::IsNullOrWhiteSpace($rawMax)) {
    $finalMaxCount = $MaxCount
} elseif ($rawMax -match '^\d+$' -and [int]$rawMax -gt 0) {
    $finalMaxCount = [int]$rawMax
} else {
    Write-Host "[错误] 输入无效，使用默认数量 $MaxCount"
    $finalMaxCount = $MaxCount
}
Write-Host "[完成] 最大保留: $finalMaxCount 张"

# ---------- 参数回显确认 ----------
Write-Host ''
Write-Host '[提示] 参数确认：'
Write-Host "  保存目录: $finalSaveDir"
Write-Host "  截图间隔: $finalInterval 秒"
Write-Host "  最大保留: $finalMaxCount 张"
Write-Host "  文件名: screenshot_0~$($finalMaxCount - 1).png（循环覆盖）"
Write-Host ''
$confirm = Read-Host '[输入] 确认开始截图？[y 开始 / q 取消]'
if ($confirm -notmatch '^[yY]$') {
    Write-Host '[提示] 已取消，未开始截图。'
    Read-Host '[结束] 按回车键退出...'
    exit 0
}

# ---------- 确保保存目录存在 ----------
if (-not (Test-Path $finalSaveDir)) {
    New-Item -ItemType Directory -Path $finalSaveDir -Force | Out-Null
}

# ---------- 文件名模板 ----------
$filePrefix = 'screenshot_'
$fileExt = '.png'

# ---------- 循环索引 ----------
$currentIndex = 0

# ---------- 启动提示 ----------
Write-Host ''
Write-Host '[进度] 开始循环截图 ...'
Write-Host '[提示] 按 Ctrl+C 可随时停止。'
Write-Host ''

# ---------- 截图函数 ----------
function Take-Screenshot {
    param([string]$Path)
    try {
        $screen = [System.Windows.Forms.Screen]::PrimaryScreen
        $bounds = $screen.Bounds
        $bitmap = New-Object System.Drawing.Bitmap($bounds.Width, $bounds.Height)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
        $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
        $graphics.Dispose()
        $bitmap.Dispose()
        return $true
    } catch {
        return $false
    }
}

# ---------- 主循环 ----------
try {
    while ($true) {
        $filename = Join-Path $finalSaveDir "$filePrefix$currentIndex$fileExt"
        $result = Take-Screenshot -Path $filename
        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        if ($result) {
            Write-Host "[完成] $timestamp 已保存: $filename"
        } else {
            Write-Host "[失败] $timestamp 截图失败，请检查屏幕截图权限"
        }
        $currentIndex = ($currentIndex + 1) % $finalMaxCount
        Start-Sleep -Seconds $finalInterval
    }
} finally {
    Write-Host ''
    Write-Host '[提示] 用户中断，脚本退出。'
    Read-Host '[结束] 按回车键退出...'
    exit 0
}
