@echo off
rem Generic PowerShell launcher.
rem Usage 1: drag a .ps1 file onto this file to run it directly.
rem Usage 2: double-click this file, then drag a .ps1 into this window
rem           (or type its path) and press Enter.
rem Usage 3: PSRunner.cmd "path\to\script.ps1" [args...]
rem Kept pure ASCII + CRLF. See the cli conventions doc for details.
setlocal
chcp 65001 >NUL

set "TARGET=%~1"
if not "%TARGET%"=="" goto run

:prompt
echo ================================================
echo   Generic PowerShell Runner
echo ================================================
echo [Mode 1] Drag a .ps1 file onto this program to run it.
echo [Mode 2] Type the path below, or drag a .ps1 into this
echo           window to fill the path automatically.
echo [Mode 3] Run from command line with extra arguments:
echo           PSRunner.cmd "script.ps1" -Subnet 192.168.1.0/24
echo [Cancel] Press Enter with an empty line to exit.
echo ================================================
set "TARGET="
set /p "TARGET=[Input] Path: "
set "TARGET=%TARGET:"=%"
if "%TARGET%"=="" goto cancel
goto run

:cancel
echo.
echo [End] Cancelled. Press any key to exit...
pause >nul
exit /b 0

:run
set "PS="
where pwsh >nul 2>nul && set "PS=pwsh"
if not defined PS (
    where powershell >nul 2>nul && set "PS=powershell"
)
if not defined PS if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "PS=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not defined PS if exist "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not defined PS (
    echo ERROR: PowerShell not found. Install PowerShell or fix PATH.
    pause
    exit /b 1
)
echo Using: %PS%

for %%D in ("%TARGET%") do set "TARGET=%%~fD"
if not exist "%TARGET%" (
    echo ERROR: file not found: %TARGET%
    echo.
    echo [End] Press any key to exit...
    pause >nul
    exit /b 1
)

rem ---- step A: ensure no BOM in target file (repo forbids BOM) ----
"%PS%" -NoProfile -ExecutionPolicy Bypass -Command "$p=$env:TARGET; $b=[IO.File]::ReadAllBytes($p); if($b.Count -ge 2 -and (($b[0]-eq 0xFF -and $b[1]-eq 0xFE) -or ($b[0]-eq 0xFE -and $b[1]-eq 0xFF))){ Write-Host '[warn] UTF-16 file detected, skipped.' } elseif($b.Count -gt 3 -and $b[0]-eq 0xEF -and $b[1]-eq 0xBB -and $b[2]-eq 0xBF){ try { [Array]::Copy($b,3,$b,0,$b.Count-3); [IO.File]::WriteAllBytes($p,$b[0..($b.Count-4)]) } catch { Write-Host ('[warn] BOM remove failed: ' + $_.Exception.Message) } }"

rem ---- step B: detect PowerShell major version ----
set "VER="
for /f "usebackq delims=" %%v in (`"%PS%" -NoProfile -Command "[int]$PSVersionTable.PSVersion.Major"`) do set "VER=%%v"
if not defined VER set "VER=5"
echo PS version: %VER%

rem ---- step C: Windows PowerShell 5.1 and older need a UTF-8 BOM to decode chinese ----
if %VER% LSS 6 (
    "%PS%" -NoProfile -ExecutionPolicy Bypass -Command "$p=$env:TARGET; $b=[IO.File]::ReadAllBytes($p); $hasUtf8Bom = $b.Count -ge 3 -and $b[0]-eq 0xEF -and $b[1]-eq 0xBB -and $b[2]-eq 0xBF; $isUtf16 = $b.Count -ge 2 -and (($b[0]-eq 0xFF -and $b[1]-eq 0xFE) -or ($b[0]-eq 0xFE -and $b[1]-eq 0xFF)); if($b.Count -gt 0 -and -not $hasUtf8Bom -and -not $isUtf16){ try { $n=[byte[]]::new($b.Length+3); $n[0]=0xEF; $n[1]=0xBB; $n[2]=0xBF; [Array]::Copy($b,0,$n,3,$b.Length); [IO.File]::WriteAllBytes($p,$n) } catch { Write-Host ('[warn] BOM add failed: ' + $_.Exception.Message) } }"
)

rem ---- step D: run the target script directly (keeps $PSScriptRoot intact) ----
for %%D in ("%TARGET%") do pushd "%%~dpD"
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%TARGET%" %2 %3 %4 %5 %6 %7 %8 %9
set "RC=%ERRORLEVEL%"
popd

rem ---- step E: always strip BOM again, restore to clean no-BOM state ----
"%PS%" -NoProfile -ExecutionPolicy Bypass -Command "$p=$env:TARGET; $b=[IO.File]::ReadAllBytes($p); if($b.Count -gt 3 -and $b[0]-eq 0xEF -and $b[1]-eq 0xBB -and $b[2]-eq 0xBF){ try { [Array]::Copy($b,3,$b,0,$b.Count-3); [IO.File]::WriteAllBytes($p,$b[0..($b.Count-4)]) } catch { Write-Host ('[warn] BOM remove failed: ' + $_.Exception.Message) } }"

echo.
echo [End] Finished (exit code: %RC%). Press any key to exit...
pause >nul
endlocal
