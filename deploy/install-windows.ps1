# ThirdHub 后端 Windows 一键安装(管理员PowerShell)
# irm https://raw.githubusercontent.com/Smalluniverseheng/ThirdHub-v2/main/deploy/install-windows.ps1 | iex
$ErrorActionPreference = 'Stop'
Write-Host "== ThirdHub 后端 Windows 安装 ==" -ForegroundColor Cyan

# 1. Node(无则装, 走 winget)
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
  winget install OpenJS.NodeJS.LTS --accept-package-agreements --accept-source-agreements
  $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
}
Write-Host "Node: $(node -v)"

# 2. 部署目录
$dest = "$env:LOCALAPPDATA\ThirdHub"
New-Item -ItemType Directory -Force $dest | Out-Null
Set-Location $dest
if (-not (Test-Path "server")) {
  Invoke-WebRequest "https://github.com/Smalluniverseheng/ThirdHub-v2/archive/main.zip" -OutFile "main.zip"
  Expand-Archive main.zip -Force; Move-Item "ThirdHub-v2-main\server" .; Remove-Item main.zip -Recurse -Force
}
Set-Location server
npm install --production

# 3. 开机自启(计划任务)
$action = New-ScheduledTaskAction -Execute "node.exe" -Argument "index.js" -WorkingDirectory "$dest\server"
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType S4U -RunLevel Highest
Register-ScheduledTask -TaskName "ThirdHub-Backend" -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null

# 4. 启动+防火墙
Start-Process node -ArgumentList "index.js" -WorkingDirectory "$dest\server" -WindowStyle Hidden
New-NetFirewallRule -DisplayName "ThirdHub-9527" -Direction Inbound -LocalPort 9527 -Protocol TCP -Action Allow -Force | Out-Null

$ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -like "192.168.*" } | Select-Object -First 1).IPAddress
Write-Host ""
Write-Host "== 安装完成 ==" -ForegroundColor Green
Write-Host "本机访问: https://${ip}:9527 (浏览器开=控制台)"
Write-Host "密钥: $(Get-Content $dest\server\data\secret -ErrorAction SilentlyContinue)"
Write-Host "指纹: 首次启动后: openssl x509 -in $dest\server\data\cert.pem -noout -fingerprint -sha256"
