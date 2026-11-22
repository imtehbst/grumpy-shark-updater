<#
  Update-Addons.ps1 - console version of the ad-free WoW addon updater.
  (Addon-Updater.ps1 is the window version; both share UpdaterCore.ps1 and addons.json.)

    .\Update-Addons.ps1            check and install updates (skips addons switched off)
    .\Update-Addons.ps1 -DryRun    only show what would change (touches nothing)
    .\Update-Addons.ps1 -Restore   put the folders from the newest backup back
    .\Update-Addons.ps1 -Notify    quiet check (run at Windows start); shows a notice only if updates are waiting
#>
param([switch]$DryRun, [switch]$Restore, [switch]$Notify, [int]$NotifyDelay = 60, [int]$NoticeSeconds = 1800)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'UpdaterCore.ps1')

function Write-Line($text, $color = 'Gray') { Write-Host $text -ForegroundColor $color }

$config = Read-Config

# Tray notice: the shark icon sits in the tray until clicked (or $NoticeSeconds pass); a click opens the window.
function Show-UpdateNotice($names) {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    $ni = New-Object Windows.Forms.NotifyIcon
    $ico = Join-Path $PSScriptRoot 'art\grumpy-shark.ico'
    $ni.Icon = if (Test-Path $ico) { New-Object Drawing.Icon($ico) } else { [Drawing.SystemIcons]::Information }
    $n = @($names).Count
    $headline = "$n addon update$(if ($n -ne 1) { 's' }) waiting"
    $ni.Text = "Grumpy Shark: $headline"
    $ni.Visible = $true
    $script:clicked = $false
    $open = { $script:clicked = $true }
    $ni.add_BalloonTipClicked($open); $ni.add_Click($open)
    $list = (@($names) | Select-Object -First 4) -join ', '
    if ($n -gt 4) { $list += '...' }
    $ni.ShowBalloonTip(10000, $headline, "$list`nClick to open the updater.", 'Info')
    $end = (Get-Date).AddSeconds($NoticeSeconds)
    while (-not $script:clicked -and (Get-Date) -lt $end) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100 }
    $ni.Dispose()
    if ($script:clicked) {
        Start-Process (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$(Join-Path $PSScriptRoot 'Addon-Updater.ps1')`""
    }
}

if ($Notify) {
    # Runs hidden at sign-in: wait for the network, check quietly, never show errors (the window shows them).
    Start-Sleep -Seconds $NotifyDelay
    try {
        if (-not $config.addonsPath -or -not (Test-Path $config.addonsPath) -or -not $config.addons.Count) { return }
        $state = Read-State; $work = New-WorkFolder; $waiting = @()
        try {
            foreach ($addon in $config.addons) {
                $s = Get-AddonStatus $config $addon $state $work
                if ($s.firstSeen) { $state[$addon.name] = $s.latest.version; Save-State $state }
                if ($s.status -eq 'update' -and -not $addon.hold) { $waiting += $addon.name }
            }
        } finally { Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue }
        $waiting   # listed when run by hand; nobody sees it at sign-in
        if ($waiting) { Show-UpdateNotice $waiting }
    } catch {}
    return
}

if ($Restore) {
    $names = Restore-LastBackup $config
    if (-not $names) { Write-Line 'No backups to restore.' Yellow; return }
    $names | ForEach-Object { Write-Line "Restored $_" Green }
    if (Test-WowRunning) { Write-Line 'WoW is open - type /reload in game to load them.' Yellow }
    return
}

if (-not $config.addonsPath -or -not (Test-Path $config.addonsPath)) {
    $found = Find-AddonsPath
    if (-not $found) { Write-Line 'Could not find your WoW Forever AddOns folder. Open the window version once and click Change folder.' Red; return }
    $config | Add-Member -NotePropertyName addonsPath -NotePropertyValue $found -Force; Save-Config $config
}
if (-not $config.addons.Count) { Write-Line 'No addons on your list yet. Open the window version and click Find my addons.' Yellow; return }
$wowOpen = Test-WowRunning
$state   = Read-State
$work    = New-WorkFolder
$backup  = New-BackupPath
$updated = 0
if ($DryRun) { Write-Line "DRY RUN - nothing will be changed`n" Cyan }

try {
    foreach ($addon in $config.addons) {
        $label = $addon.name.PadRight(26)
        $s = Get-AddonStatus $config $addon $state $work
        switch ($s.status) {
            'error'   { Write-Line "$label could not check: $($s.message)" Red }
            'current' {
                Write-Line "$label up to date ($($s.latest.version))" DarkGray
                if ($s.firstSeen -and -not $DryRun) { $state[$addon.name] = $s.latest.version; Save-State $state }
            }
            'update'  {
                $from = if ($state[$addon.name]) { $state[$addon.name] } else { 'installed copy' }
                if ($addon.hold) { Write-Line "$label OFF - $($s.latest.version) available (switched off)" Yellow }
                elseif ($DryRun) { Write-Line "$label would update: $from -> $($s.latest.version)" Cyan }
                else {
                    Install-Addon $config $addon $s.latest $work $backup | Out-Null
                    $state[$addon.name] = $s.latest.version; Save-State $state
                    $updated++
                    Write-Line "$label updated: $from -> $($s.latest.version)" Green
                }
            }
        }
    }
} finally {
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}
Remove-OldBackups

Write-Line ''
if ($DryRun)      { Write-Line 'Dry run finished.' Cyan }
elseif ($updated) {
    Write-Line "$updated addon(s) updated. Old copies are in $backup (run with -Restore to undo)." Green
    if ($wowOpen) { Write-Line 'WoW is open - type /reload in game to load the new versions.' Yellow }
}
else              { Write-Line 'Everything is up to date.' Green }
