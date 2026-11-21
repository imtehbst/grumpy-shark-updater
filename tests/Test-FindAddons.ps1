# Self-check for Find-NewAddons against the real AddOns folder (needs internet for CurseForge checks).
# Run: powershell -ExecutionPolicy Bypass -File tests\Test-FindAddons.ps1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\UpdaterCore.ps1')

$c = Read-Config
$again = @(Find-NewAddons $c)
if ($again.Count -ne 0) { throw "already-tracked addons were offered again: $($again.name -join ', ')" }

$fresh = $c.PSObject.Copy(); $fresh.addons = @()
$found = @(Find-NewAddons $fresh)
foreach ($a in $c.addons) {
    if ($found.name -notcontains $a.name) { throw "a fresh scan missed $($a.name)" }
}
if (@($found | Where-Object { -not $_.entry.source }).Count) { throw 'a candidate has no source' }
'Find-NewAddons OK'
