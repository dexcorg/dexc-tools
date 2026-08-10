@echo off
rem Generic PowerShell launcher.
rem Usage 1: drag a .ps1 file onto this file to run it directly.
rem Usage 2: double-click this file, then drag a .ps1 into this window
rem           (or type its path) and press Enter.
rem Kept pure ASCII + CRLF. See the cli conventions doc for details.
setlocal

set "TARGET=%~1"
if not "%TARGET%"=="" goto run

:prompt
echo ================================================
echo   DEXC PowerShell Runner
echo ================================================
echo [Mode 1] Drag a .ps1 file onto this program to run it.
echo [Mode 2] Type the path below, or drag a .ps1 into this
echo           window to fill the path automatically.
echo [Cancel] Press Enter with an empty line to exit.
echo ================================================
set "TARGET="
set /p "TARGET=Path: "
set "TARGET=%TARGET:"=%"
if "%TARGET%"=="" goto cancel
goto run

:cancel
echo.
echo Cancelled. Press any key to exit...
pause >nul
exit /b 0

:run
set "PS=pwsh"
where pwsh >nul 2>nul || set "PS=powershell"

rem EncodedCommand (UTF-16LE Base64) of the following bootstrap:
rem   $p = $env:TARGET
rem   if (-not $p) { Write-Host 'TARGET is empty'; Read-Host 'Press Enter'; exit 1 }
rem   try { $c = [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8) }
rem   catch { Write-Host ('Read failed: ' + $_.Exception.Message); Read-Host 'Press Enter'; exit 1 }
rem   try { [scriptblock]::Create($c).Invoke() }
rem   catch { Write-Host ('Script error: ' + $_.Exception.Message); Read-Host 'Press Enter'; exit 1 }
set "BC=JABwACAAPQAgACQAZQBuAHYAOgBUAEEAUgBHAEUAVAAKAGkAZgAgACgALQBuAG8AdAAgACQAcAApACAAewAgAFcAcgBpAHQAZQAtAEgAbwBzAHQAIAAnAFQAQQBSAEcARQBUACAAaQBzACAAZQBtAHAAdAB5ACcAOwAgAFIAZQBhAGQALQBIAG8AcwB0ACAAJwBQAHIAZQBzAHMAIABFAG4AdABlAHIAJwA7ACAAZQB4AGkAdAAgADEAIAB9AAoAdAByAHkAIAB7ACAAJABjACAAPQAgAFsASQBPAC4ARgBpAGwAZQBdADoAOgBSAGUAYQBkAEEAbABsAFQAZQB4AHQAKAAkAHAALAAgAFsAVABlAHgAdAAuAEUAbgBjAG8AZABpAG4AZwBdADoAOgBVAFQARgA4ACkAIAB9AAoAYwBhAHQAYwBoACAAewAgAFcAcgBpAHQAZQAtAEgAbwBzAHQAIAAoACcAUgBlAGEAZAAgAGYAYQBpAGwAZQBkADoAIAAnACAAKwAgACQAXwAuAEUAeABjAGUAcAB0AGkAbwBuAC4ATQBlAHMAcwBhAGcAZQApADsAIABSAGUAYQBkAC0ASABvAHMAdAAgACcAUAByAGUAcwBzACAARQBuAHQAZQByACcAOwAgAGUAeABpAHQAIAAxACAAfQAKAHQAcgB5ACAAewAgAFsAcwBjAHIAaQBwAHQAYgBsAG8AYwBrAF0AOgA6AEMAcgBlAGEAdABlACgAJABjACkALgBJAG4AdgBvAGsAZQAoACkAIAB9AAoAYwBhAHQAYwBoACAAewAgAFcAcgBpAHQAZQAtAEgAbwBzAHQAIAAoACcAUwBjAHIAaQBwAHQAIABlAHIAcgBvAHIAOgAgACcAIAArACAAJABfAC4ARQB4AGMAZQBwAHQAaQBvAG4ALgBNAGUAcwBzAGEAZwBlACkAOwAgAFIAZQBhAGQALQBIAG8AcwB0ACAAJwBQAHIAZQBzAHMAIABFAG4AdABlAHIAJwA7ACAAZQB4AGkAdAAgADEAIAB9AA=="

%PS% -NoProfile -ExecutionPolicy Bypass -EncodedCommand "%BC%"

echo.
echo Finished. Press any key to exit...
pause >nul
endlocal
