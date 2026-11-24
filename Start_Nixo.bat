@echo off
setlocal
cd /d "%~dp0"

where py >nul 2>&1
if errorlevel 1 (
  echo [NIXO] Python launcher "py" not found on PATH.
  echo [NIXO] Install Python 3.12, then run this again.
  pause
  exit /b 1
)

echo [NIXO] Starting engine (separate window)...
start "NIXO Engine" cmd /k "cd /d "%~dp0engine_py" && py -3 -m nixo_engine.execution --config .\engine_config.json --engine-db .\data\nixo_engine.db"

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
