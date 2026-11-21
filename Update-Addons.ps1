<#
  Update-Addons.ps1 - console version of the ad-free WoW addon updater.
  (Addon-Updater.ps1 is the window version; both share UpdaterCore.ps1 and addons.json.)

    .\Update-Addons.ps1            check and install updates (skips addons switched off)
    .\Update-Addons.ps1 -DryRun    only show what would change (touches nothing)
    .\Update-Addons.ps1 -Restore   put the folders from the newest backup back
#>
param([switch]$DryRun, [switch]$Restore)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'UpdaterCore.ps1')

function Write-Line($text, $color = 'Gray') { Write-Host $text -ForegroundColor $color }

$config = Read-Config

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
