@echo off
rem One-time setup: add "Run with PowerShell" to the right-click menu of .ps1 files (current user, no admin needed).
reg add "HKCU\Software\Classes\Microsoft.PowerShellScript.1\Shell\RunWithPowerShell" /ve /d "Run with PowerShell" /f >nul
reg add "HKCU\Software\Classes\Microsoft.PowerShellScript.1\Shell\RunWithPowerShell\Command" /ve /d "powershell.exe -NoLogo -ExecutionPolicy Bypass -File \"%%1\"" /f >nul
echo.
echo Done. Now right-click any .ps1 file and choose "Run with PowerShell".
pause
