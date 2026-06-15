' Launches Diktatorn.ps1 fully hidden (no console window). Lives in the system tray.
Set sh = CreateObject("WScript.Shell")
root = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\"))
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File """ & root & "Diktatorn.ps1""", 0, False
