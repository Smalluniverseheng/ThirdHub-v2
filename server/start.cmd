@echo off
chcp 65001 >nul 2>&1
setlocal enabledelayedexpansion
rem ============================================================
rem  ThirdHub v4 backend - one-click start (Windows)
rem  - auto: check node / install deps if missing / start :9527
rem  - npm registry: npmmirror (npmjs.org direct is very slow here)
rem ============================================================
cd /d "%~dp0"

set "NPM_REG=https://registry.npmmirror.com"
set "NODE_OK="
where node >nul 2>&1 && set "NODE_OK=1"

if not defined NODE_OK (
  echo [X] Node.js not found. Install Node 20+ first:
  echo     winget install OpenJS.NodeJS.LTS
  echo     https://nodejs.org/
  pause
  exit /b 1
)

for /f "delims=" %%v in ('node -v') do set "NODEV=%%v"
echo [*] Node %NODEV%

rem --- kill any leftover RPC listener from a previous run ---
if exist "vendor\aria2\aria2c.exe" (
  echo [*] aria2c present - P2P/BT enabled
) else (
  echo [!] vendor\aria2\aria2c.exe missing - torrent/magnet disabled
  echo     put aria2c.exe into server\vendor\aria2\ to enable P2P
)

rem --- deps ---
if not exist "node_modules\cheerio\package.json" (
  echo [*] installing dependencies ^(first run^)...
  call npm install --no-audit --no-fund --registry=%NPM_REG%
  if errorlevel 1 (
    echo [X] npm install failed.
    echo     If the error mentions a host like npm.mirrors.msh.team, the lockfile
    echo     is pinned to an unreachable mirror. Fix:
    echo         del package-lock.json ^&^& npm install --registry=%NPM_REG%
    pause
    exit /b 2
  )
)

echo [*] starting backend on https://0.0.0.0:9527 ...
echo     first run generates a self-signed cert into server\data\
echo     press Ctrl+C to stop
echo.
node index.js
set "RC=%ERRORLEVEL%"
echo.
echo [*] backend exited with code %RC%
if "%RC%"=="2" echo     code 2 = missing dependencies. run: npm install --registry=%NPM_REG%
pause
endlocal
