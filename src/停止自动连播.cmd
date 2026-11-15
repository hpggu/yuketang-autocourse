@echo off
title Yuketang AutoCourse - Stop
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$marker = Join-Path '%~dp0' 'STOP_AUTOCOURSE'; Set-Content -LiteralPath $marker -Value 'stop' -Encoding ASCII"
echo [AutoCourse] stop request sent.
ping -n 2 127.0.0.1 >nul