@echo off
setlocal

echo [NIXO] Stopping engine window...
taskkill /FI "WINDOWTITLE eq NIXO Engine*" /T /F >nul 2>&1

echo [NIXO] Stopping any process still listening on 9124 / 9123 ...
for %%P in (9124 9123) do (
  for /f "tokens=5" %%A in ('netstat -ano ^| findstr /R /C:"LISTENING" ^| findstr ":%%P "') do (
    taskkill /PID %%A /T /F >nul 2>&1
  )
)

echo [NIXO] Done. State is persisted in engine_py\data\nixo_engine.db.
endlocal
