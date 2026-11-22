@echo off
setlocal
set BASE=http://127.0.0.1:9124

echo === NIXO health ===
powershell -NoProfile -Command "try { $r=Invoke-WebRequest -UseBasicParsing -Uri '%BASE%/health' -TimeoutSec 3 -Headers @{Authorization=('Bearer '+$env:NIXO_TOKEN)}; Write-Host ('health: ' + $r.StatusCode + ' ' + $r.Content) } catch { Write-Host ('health: FAILED - ' + $_.Exception.Message) }"

powershell -NoProfile -Command "try { $r=Invoke-WebRequest -UseBasicParsing -Uri '%BASE%/status' -TimeoutSec 3 -Headers @{Authorization=('Bearer '+$env:NIXO_TOKEN)}; Write-Host ('status: ' + $r.StatusCode); Write-Host $r.Content } catch { Write-Host ('status: FAILED - ' + $_.Exception.Message) }"

echo === listeners on 9123 / 9124 ===
netstat -ano | findstr /R /C:"LISTENING" | findstr ":9123 :9124"
endlocal
