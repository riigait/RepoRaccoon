@echo off
rem RepoRaccoon launcher for CMD / Windows Terminal (PowerShell runs reporaccoon.ps1 directly).
if "%~1"=="/?" goto help
if /i "%~1"=="--help" goto help
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0reporaccoon.ps1" %*
exit /b %errorlevel%
:help
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0reporaccoon.ps1" -h
