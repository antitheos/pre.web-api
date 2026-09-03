:: Runs the same check as the MACHINE ACCOUNT, which is what an IIS app pool
:: using ApplicationPoolIdentity presents as over the network. Your own
:: account succeeding proves nothing about the API's.
::
:: No PsExec needed — a scheduled task running as SYSTEM does it.
:: Run from an elevated prompt, in the folder holding the .ps1.

schtasks /create /tn mirthcheck /f /sc once /st 00:00 /ru SYSTEM ^
  /tr "powershell -ExecutionPolicy Bypass -File \"%CD%\mirth_connection_check.ps1\" > \"%CD%\mirthcheck.txt\" 2>&1"
schtasks /run /tn mirthcheck
timeout /t 15 >nul
type "%CD%\mirthcheck.txt"
schtasks /delete /tn mirthcheck /f
