# 系统图标缓存清理工具（PowerShell · UTF-8 无 BOM）
$null = chcp 65001
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$sep = '=' * 50
Write-Host $sep
Write-Host "            系统图标缓存清理工具"
Write-Host "            版本 1.0"
Write-Host $sep
Write-Host "[适用场景]"
Write-Host "当 Windows 部分应用图标某天突然无法正常显示、缩略图错乱时使用。"
Write-Host ""
Write-Host "[功能说明]"
Write-Host "本脚本将执行以下操作："
Write-Host "  1. 关闭 Windows 资源管理器 (explorer.exe)"
Write-Host "  2. 删除系统图标缓存数据库文件"
Write-Host "  3. 清理缩略图缓存与系统托盘记忆图标"
Write-Host "  4. 自动重启 Windows 资源管理器"
Write-Host ""
Write-Host "[操作方式]"
Write-Host "确认无误后输入选项数字 1 开始执行，输入 q 取消。"
Write-Host ""
Write-Host "[执行步骤]"
Write-Host "1. 关闭 Windows 资源管理器"
Write-Host "2. 删除系统图标缓存数据库文件"
Write-Host "3. 清理缩略图缓存与系统托盘记忆图标"
Write-Host "4. 自动重启 Windows 资源管理器"
Write-Host ""
Write-Host "[注意事项]"
Write-Host "- 执行过程中桌面和任务栏将短暂消失，请勿惊慌。"
Write-Host "- 建议以管理员身份运行，以确保权限充足。"
Write-Host "- 关闭资源管理器前请先保存好其它程序的工作内容。"
Write-Host $sep

# 管理员权限检查
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "[提示] 未检测到管理员权限，部分操作可能失败。"
    Write-Host "        建议关闭后右键以管理员权限运行。"
    $ok = Read-Host "是否仍要继续？[y 继续 / n 取消]"
    if ($ok -notmatch '^[yY]$') { Write-Host "[提示] 已取消，未做任何修改。"; Read-Host "按回车键退出..."; exit 0 }
    Write-Host ""
}

# 菜单选择
while ($true) {
    $choice = Read-Host "请输入选项数字 [1 开始执行 / q 取消] 然后按回车"
    if ($choice -eq '1') { break }
    if ($choice -match '^[qQ]$') { Write-Host "[提示] 已取消，未做任何修改。"; Read-Host "按回车键退出..."; exit 0 }
    Write-Host "[错误] 无效输入，请输入 1 或 q。"
}

$fail = 0
Write-Host ""
Write-Host "[进度] 步骤 1/4：关闭 Windows 资源管理器 ..."
Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500
Write-Host "[提示] 已向资源管理器发送关闭指令，请确认桌面是否消失。"

Write-Host ""
Write-Host "[进度] 步骤 2/4：删除系统图标缓存数据库文件 ..."
$iconDb = Join-Path $env:LOCALAPPDATA 'IconCache.db'
if (Test-Path $iconDb) {
    Remove-Item -Path $iconDb -Force -ErrorAction SilentlyContinue
    if (Test-Path $iconDb) { Write-Host "[失败] 图标缓存数据库删除失败。"; $fail++ }
    else { Write-Host "[完成] 图标缓存数据库已删除。" }
} else { Write-Host "[完成] 未发现图标缓存数据库文件。" }

Write-Host ""
Write-Host "[进度] 步骤 3/4：清理缩略图缓存与系统托盘记忆图标 ..."
$explorerDir = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer'
Get-ChildItem -Path $explorerDir -Filter 'thumbcache_*.db' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
Remove-ItemProperty -Path 'Registry::HKEY_CLASSES_ROOT\Local Settings\Software\Microsoft\Windows\CurrentVersion\TrayNotify' -Name 'IconStreams' -ErrorAction SilentlyContinue
Remove-ItemProperty -Path 'Registry::HKEY_CLASSES_ROOT\Local Settings\Software\Microsoft\Windows\CurrentVersion\TrayNotify' -Name 'PastIconsStream' -ErrorAction SilentlyContinue
Write-Host "[完成] 缩略图缓存与托盘记忆图标已清理。"

Write-Host ""
Write-Host "[进度] 步骤 4/4：重启 Windows 资源管理器 ..."
Start-Process explorer.exe
Write-Host "[完成] 资源管理器已重启。"

Write-Host ""
Write-Host "[结果] 执行完成。"
if ($fail -eq 0) { Write-Host "  全部步骤成功，图标缓存清理完成。" }
else { Write-Host "  失败步骤数：$fail/4，请检查后重新运行。" }
Read-Host "按回车键退出..."
exit 0
