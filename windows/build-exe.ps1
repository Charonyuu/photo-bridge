# 在 Windows 上產生 dist\PhotoBridge.exe（需要 Node.js 25.5 以上，只有打包的人要裝）
# 用法：powershell -ExecutionPolicy Bypass -File build-exe.ps1
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot
npm install --silent
npx --yes esbuild@0.24.0 src/entry.js --bundle --platform=node --target=node20 --format=cjs --outfile=dist/bundle.js --log-level=warning
node --build-sea sea-config.json
Compress-Archive -Force dist\PhotoBridge.exe dist\PhotoBridge-Windows.zip
Write-Output "完成：dist\PhotoBridge.exe、dist\PhotoBridge-Windows.zip"
