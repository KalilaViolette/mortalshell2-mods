@echo off
setlocal
cd /d "%~dp0"
set "MSTTS_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%MSTTS_PS%" set "MSTTS_PS=powershell.exe"
"%MSTTS_PS%" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0CollectSupportBundle.ps1"
set "MSTTS_EXIT=%ERRORLEVEL%"
echo.
if "%MSTTS_EXIT%"=="0" (
  echo MortalShell2TTS support bundle finished successfully.
) else (
  echo MortalShell2TTS support bundle failed with exit code %MSTTS_EXIT%.
  echo Check the message above. Enterprise PowerShell policy can still block scripts even with ExecutionPolicy Bypass.
)
echo.
pause
exit /b %MSTTS_EXIT%
