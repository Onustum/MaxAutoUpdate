' LaunchHidden.vbs - тихий запуск Install-Max.ps1
Set objShell = CreateObject("WScript.Shell")
objShell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File ""Folde\To\User\Scripts\Logon\Install-Max.ps1""", 0, False