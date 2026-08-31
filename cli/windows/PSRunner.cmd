@echo off
rem Generic PowerShell launcher.
rem Usage 1: drag a .ps1 file onto this file to run it directly.
rem Usage 2: double-click this file to view and select .ps1 scripts
rem           in current directory, or type / drag a .ps1 path.
rem Usage 3: PSRunner.cmd "path\to\script.ps1" [args...]
rem Kept pure ASCII + CRLF. See the cli conventions doc for details.
setlocal

set "TARGET=%~1"
if not "%TARGET%"=="" goto run

:prompt
echo ================================================
echo   Generic PowerShell Runner
echo   Version 2.0
echo ================================================

rem ---- scan current directory for .ps1 scripts ----
set "SCRIPT_COUNT=0"
for %%F in ("%~dp0*.ps1") do (
    set /a SCRIPT_COUNT+=1
    call set "SCRIPT_PATH_%%SCRIPT_COUNT%%=%%~fF"
    call set "SCRIPT_NAME_%%SCRIPT_COUNT%%=%%~nxF"
)

if %SCRIPT_COUNT% GTR 0 (
    echo [Scripts in current directory]
    for /l %%I in (1,1,%SCRIPT_COUNT%) do (
        call echo   [%%I] %%SCRIPT_NAME_%%I%%
    )
    echo.
    echo [Usage]
    echo   - Enter a number ^(1-%SCRIPT_COUNT%^) to run the script.
    echo   - Or type / drag a .ps1 file path here.
    echo   - Press Enter or 'q' to exit.
) else (
    echo [Notice] No .ps1 scripts found in current directory.
    echo.
    echo [Usage]
    echo   - Type a full/relative path or drag a .ps1 file here.
    echo   - Press Enter or 'q' to exit.
)
echo ================================================

:prompt_input_loop
set "USER_INPUT="
set /p "USER_INPUT=[Input] Select script or enter path: "
set "USER_INPUT=%USER_INPUT:"=%"
if "%USER_INPUT%"=="" goto cancel
if /i "%USER_INPUT%"=="q" goto cancel

rem Check if input matches a script number
set "RESOLVED_TARGET="
call set "RESOLVED_TARGET=%%SCRIPT_PATH_%USER_INPUT%%%"
if defined RESOLVED_TARGET (
    set "TARGET=%RESOLVED_TARGET%"
    goto run
)

rem Check if input is a valid file path (direct or relative)
if exist "%USER_INPUT%" (
    set "TARGET=%USER_INPUT%"
    goto run
)

echo.
echo [Error] Invalid choice or file not found: %USER_INPUT%
echo.
goto prompt_input_loop

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

rem ---- step B: Windows PowerShell 5.1 and older need a UTF-8 BOM to decode chinese ----
"%PS%" -NoProfile -ExecutionPolicy Bypass -Command "$p=$env:TARGET; $b=[IO.File]::ReadAllBytes($p); $hasUtf8Bom = $b.Count -ge 3 -and $b[0]-eq 0xEF -and $b[1]-eq 0xBB -and $b[2]-eq 0xBF; $isUtf16 = $b.Count -ge 2 -and (($b[0]-eq 0xFF -and $b[1]-eq 0xFE) -or ($b[0]-eq 0xFE -and $b[1]-eq 0xFF)); if($PSVersionTable.PSVersion.Major -lt 6 -and $b.Count -gt 0 -and -not $hasUtf8Bom -and -not $isUtf16){ try { $n=[byte[]]::new($b.Length+3); $n[0]=0xEF; $n[1]=0xBB; $n[2]=0xBF; [Array]::Copy($b,0,$n,3,$b.Length); [IO.File]::WriteAllBytes($p,$n) } catch { Write-Host ('[warn] BOM add failed: ' + $_.Exception.Message) } }"

rem ---- step C: run the target script directly (keeps $PSScriptRoot intact) ----
for %%D in ("%TARGET%") do pushd "%%~dpD"
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%TARGET%" %2 %3 %4 %5 %6 %7 %8 %9
set "RC=%ERRORLEVEL%"
popd

rem ---- step D: always strip BOM again, restore to clean no-BOM state ----
"%PS%" -NoProfile -ExecutionPolicy Bypass -Command "$p=$env:TARGET; $b=[IO.File]::ReadAllBytes($p); if($b.Count -gt 3 -and $b[0]-eq 0xEF -and $b[1]-eq 0xBB -and $b[2]-eq 0xBF){ try { [Array]::Copy($b,3,$b,0,$b.Count-3); [IO.File]::WriteAllBytes($p,$b[0..($b.Count-4)]) } catch { Write-Host ('[warn] BOM remove failed: ' + $_.Exception.Message) } }"

echo.
echo [End] Finished (exit code: %RC%). Press any key to exit...
pause >nul
endlocal
