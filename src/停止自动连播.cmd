@echo off
chcp 65001 >nul
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$marker = Join-Path '%~dp0' 'STOP_AUTOCOURSE'; Set-Content -LiteralPath $marker -Value 'stop' -Encoding ASCII"
echo 已发送停止请求，自动连播窗口会在 2 秒内退出。
ping -n 3 127.0.0.1 >nul