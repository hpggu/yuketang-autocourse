@echo off
chcp 65001 >nul
title 雨课堂自动连播
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0AutoCourse.ps1"
echo.
echo 脚本已结束，按任意键关闭窗口。
pause >nul