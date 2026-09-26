@echo off
rem findergit launcher for CMD / Windows Terminal (PowerShell runs findergit.ps1 directly).
if "%~1"=="/?" goto help
if /i "%~1"=="--help" goto help
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0findergit.ps1" %*
exit /b %errorlevel%
:help
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0findergit.ps1" -h
