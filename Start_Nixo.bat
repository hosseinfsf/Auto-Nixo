@echo off
setlocal
cd /d "%~dp0"

where dart >nul 2>&1
if errorlevel 1 (
  echo [NIXO] Dart SDK not found on PATH.
  echo [NIXO] Install Dart or Flutter, then run this again.
  pause
  exit /b 1
)

if not exist "apps\engine\data" mkdir "apps\engine\data"

echo [NIXO] Starting engine (separate window)...
start "NIXO Engine" cmd /k "cd /d "%~dp0apps\engine" && dart run bin\engine.dart"

echo [NIXO] Waiting for the HTTP API on 127.0.0.1:9124 ...
powershell -NoProfile -Command "$ok=$false; for($i=0;$i -lt 30;$i++){ try { $r=Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:9124/health' -TimeoutSec 1 -Headers @{Authorization=('Bearer '+$env:NIXO_TOKEN)}; if($r.StatusCode -eq 200){$ok=$true;break} } catch {}; Start-Sleep -Milliseconds 500 }; if($ok){exit 0}else{exit 1}"

if errorlevel 1 (
  echo [NIXO] API did not answer. Check the engine window for errors.
  echo [NIXO] If the API requires a token, set NIXO_TOKEN before running.
  pause
  exit /b 1
)

echo [NIXO] Engine is up. Opening dashboard...
start "" "http://127.0.0.1:9124/"
echo [NIXO] Dashboard: http://127.0.0.1:9124/
echo [NIXO] Closing the browser does NOT stop the engine.
endlocal
