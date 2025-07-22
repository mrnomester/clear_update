' Скрытое выполнение PowerShell-скрипта
Set objShell = CreateObject("WScript.Shell")
strCommand = "powershell.exe -ExecutionPolicy Bypass -File ""\\nas\Distrib\script\clear_update\clear_update_unsuccessful.ps1"""
objShell.Run strCommand, 0, False