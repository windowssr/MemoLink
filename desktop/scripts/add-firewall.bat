@echo off
:: Add Windows Firewall inbound rule for MemoLink TCP 47820 (UAC elevation)
net session >nul 2>&1
if %errorLevel% neq 0 (
  echo Requesting administrator privileges...
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)

netsh advfirewall firewall delete rule name="MemoLink Port 47820" >nul 2>&1
netsh advfirewall firewall add rule name="MemoLink Port 47820" dir=in action=allow protocol=TCP localport=47820
if %errorLevel% equ 0 (
  echo OK: Firewall rule added for TCP 47820
) else (
  echo FAILED: could not add firewall rule
)
pause
