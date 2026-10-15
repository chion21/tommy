@echo off
chcp 65001 >nul
title Tommy Server
cd /d "%~dp0"

where python >nul 2>nul
if errorlevel 1 (
  echo Python is not installed. Install it from https://www.python.org/downloads/
  echo IMPORTANT: tick "Add python.exe to PATH" during install, then run this file again.
  pause
  exit /b 1
)

if not exist ".venv\Scripts\python.exe" (
  echo Setting up for the first time, please wait 1-2 minutes...
  python -m venv .venv
  ".venv\Scripts\python.exe" -m pip install --upgrade pip >nul
  ".venv\Scripts\python.exe" -m pip install -r requirements.txt
  if errorlevel 1 (
    echo Install failed. Check your internet and run again.
    pause
    exit /b 1
  )
)

".venv\Scripts\python.exe" local_run.py
pause
