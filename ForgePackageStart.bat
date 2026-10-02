@echo off
title ForgePackage
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -NoExit -File "%~dp0ForgePackage.ps1"