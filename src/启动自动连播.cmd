@echo off
title Yuketang AutoCourse
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0AutoCourse.ps1"
echo.
echo [AutoCourse] finished. Press any key to close.
pause >nul