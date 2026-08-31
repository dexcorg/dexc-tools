@echo off
rem Generic Python launcher.
rem Usage 1: drag a .py file onto this file to run it directly.
rem Usage 2: double-click this file to auto-provision the .venv and run
rem           .py scripts in current directory, or type / drag a .py path.
rem Usage 3: PYRunner.cmd "path\to\script.py" [args...]
rem Kept pure ASCII + CRLF. See the cli conventions doc for details.
setlocal

set "BASE=%~dp0"
set "TARGET=%~1"
chcp 65001 >nul
set "PYTHONUTF8=1"
set "PYTHONIOENCODING=utf-8"

if not "%TARGET%"=="" goto run

:prompt
echo ================================================
echo   Generic Python Runner
echo   Version 1.0
echo ================================================

rem ---- scan current directory for .py scripts ----
set "SCRIPT_COUNT=0"
for %%F in ("%BASE%*.py") do (
    if /i not "%%~nxF"=="PYRunner.cmd" (
        set /a SCRIPT_COUNT+=1
        call set "SCRIPT_PATH_%%SCRIPT_COUNT%%=%%~fF"
        call set "SCRIPT_NAME_%%SCRIPT_COUNT%%=%%~nxF"
    )
)

if %SCRIPT_COUNT% GTR 0 (
    echo [Scripts in current directory]
    for /l %%I in (1,1,%SCRIPT_COUNT%) do (
        call echo   [%%I] %%SCRIPT_NAME_%%I%%
    )
    echo.
    echo [Usage]
    echo   - Enter a number ^(1-%SCRIPT_COUNT%^) to run the script.
    echo   - Or type / drag a .py file path here.
    echo   - Press Enter or 'q' to exit.
) else (
    echo [Notice] No .py scripts found in current directory.
    echo.
    echo [Usage]
    echo   - Type a full/relative path or drag a .py file here.
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
rem ---- step 1: detect system python ----
set "PY="
where python >nul 2>nul && set "PY=python"
if not defined PY (
    where python3 >nul 2>nul && set "PY=python3"
)
if not defined PY (
    echo ERROR: Python not found. Install Python or fix PATH.
    echo.
    echo [End] Press any key to exit...
    pause >nul
    exit /b 1
)
echo [Progress] Using system Python: %PY%

rem ---- step 2: normalize target path ----
for %%D in ("%TARGET%") do set "TARGET=%%~fD"
if not exist "%TARGET%" (
    echo ERROR: file not found: %TARGET%
    echo.
    echo [End] Press any key to exit...
    pause >nul
    exit /b 1
)
for %%X in ("%TARGET%") do set "TARGET_EXT=%%~xX"
if /i not "%TARGET_EXT%"==".py" (
    echo ERROR: not a .py file: %TARGET%
    echo.
    echo [End] Press any key to exit...
    pause >nul
    exit /b 1
)

rem ---- step 3: ensure .venv exists ----
if not exist "%BASE%.venv\Scripts\python.exe" (
    echo [Progress] Creating virtual environment...
    "%PY%" -m venv "%BASE%.venv"
    if errorlevel 1 (
        echo [Fail] Failed to create virtual environment.
        echo.
        echo [End] Press any key to exit...
        pause >nul
        exit /b 1
    )
)
set "VPY=%BASE%.venv\Scripts\python.exe"
echo [Progress] Using venv Python.

rem ---- step 4: install dependencies (idempotent) ----
if exist "%BASE%requirements.txt" (
    echo [Progress] Ensuring dependencies...
    "%VPY%" -m pip install -r "%BASE%requirements.txt"
    if errorlevel 1 (
        echo [Fail] Dependency install failed.
        echo.
        echo [End] Press any key to exit...
        pause >nul
        exit /b 1
    )
    echo [Progress] Dependencies ready.
)

rem ---- step 5: run the target script ----
for %%D in ("%TARGET%") do pushd "%%~dpD"
"%VPY%" -X utf8 -u "%TARGET%" %2 %3 %4 %5 %6 %7 %8 %9
set "RC=%ERRORLEVEL%"
popd

echo.
echo [End] Finished (exit code: %RC%). Press any key to exit...
pause >nul
endlocal
