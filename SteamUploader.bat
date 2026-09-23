@echo off
setlocal EnableExtensions DisableDelayedExpansion
powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0SteamUploader.ps1" %*
set "RESULT=%ERRORLEVEL%"
if not "%STEAM_UPLOADER_NO_PAUSE%"=="1" if not "%STEAM_PUBLISHER_NO_PAUSE%"=="1" pause
exit /b %RESULT%
