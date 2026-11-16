@echo off
chcp 65001 >nul
cd /d "%~dp0"
where node >nul 2>nul
if errorlevel 1 (
  echo 找不到 Node.js，請先到 https://nodejs.org 安裝 LTS 版本，再重新開啟這個檔案。
  pause
  exit /b 1
)
if not exist node_modules (
  echo 第一次執行，安裝需要的套件...
  call npm install --omit=dev
)
node src\server.js
pause
