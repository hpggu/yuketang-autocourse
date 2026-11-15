@echo off
setlocal enabledelayedexpansion
title Yuketang AutoCourse v2
set "PORT=9222"
set "HERE=%~dp0"
set "PS1=%HERE%AutoCourse.ps1"
set "EDGE=C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"
set "EDGE2=C:\Program Files\Microsoft\Edge\Application\msedge.exe"
set "CHROME=C:\Program Files\Google\Chrome\Application\chrome.exe"

powershell -NoProfile -Command "try{Invoke-RestMethod -Uri ('http://127.0.0.1:%PORT%/json/version') -TimeoutSec 2 | Out-Null; exit 0}catch{exit 1}"
if not errorlevel 1 goto run

echo [1/3] Debug port %PORT% is closed, restarting the browser with remote debugging.
echo       Tabs will come back through the browser session restore.
taskkill /IM msedge.exe /F >nul 2>&1
taskkill /IM chrome.exe /F >nul 2>&1
timeout /t 2 /nobreak >nul

set "BROWSER="
if exist "%EDGE%" set "BROWSER=%EDGE%"
if not defined BROWSER if exist "%EDGE2%" set "BROWSER=%EDGE2%"
if not defined BROWSER if exist "%CHROME%" set "BROWSER=%CHROME%"
if not defined BROWSER (
  echo Could not find msedge.exe or chrome.exe.
  pause
  exit /b 1
)

start "" "%BROWSER%" --remote-debugging-port=%PORT% --restore-last-session

echo [2/3] Waiting for the debug port to answer...
set /a TRIES=0
:wait
powershell -NoProfile -Command "try{Invoke-RestMethod -Uri ('http://127.0.0.1:%PORT%/json/version') -TimeoutSec 2 | Out-Null; exit 0}catch{exit 1}"
if not errorlevel 1 goto run
set /a TRIES+=1
if %TRIES% GEQ 30 (
  echo Debug port still closed after 30 seconds.
  pause
  exit /b 1
)
timeout /t 1 /nobreak >nul
goto wait

:run
echo [3/3] Starting AutoCourse v2 ...
echo       Open the Yuketang video page in the browser first if it is not there yet.
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
echo.
echo [AutoCourse] finished. Press any key to close.
pause >nul
