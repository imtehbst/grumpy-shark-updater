# Creates the "Grumpy Shark Updater" desktop shortcut. Run via Setup.cmd.
$here = $PSScriptRoot
Get-ChildItem $here -Recurse -File | Unblock-File   # clear Windows' "downloaded from the internet" mark
$lnkPath = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Grumpy Shark Updater.lnk'
$s = (New-Object -ComObject WScript.Shell).CreateShortcut($lnkPath)
$s.TargetPath = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$s.Arguments = "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$here\Addon-Updater.ps1`""
$s.WorkingDirectory = $here
$s.IconLocation = "$here\art\icon.ico,0"
$s.WindowStyle = 7
$s.Save()
Write-Host 'Done! Double-click "Grumpy Shark Updater" on your desktop.' -ForegroundColor Green
