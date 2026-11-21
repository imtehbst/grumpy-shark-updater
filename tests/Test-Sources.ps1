# Self-check for WoWInterface support, early-access filtering and leftover-folder cleanup.
# Works in a throwaway copy with a fake AddOns folder - never touches the real one. Needs internet.
# Run: powershell -ExecutionPolicy Bypass -File tests\Test-Sources.ps1
$ErrorActionPreference = 'Stop'
$src = Split-Path $PSScriptRoot -Parent
$box = Join-Path $env:TEMP ('gsu-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory "$box\app", "$box\AddOns" | Out-Null
Copy-Item "$src\UpdaterCore.ps1", "$src\known-addons.json" "$box\app"
function Assert($ok, $msg) { if (-not $ok) { throw "FAIL: $msg" }; "ok   $msg" }

try {
    . "$box\app\UpdaterCore.ps1"
    $cfg = [pscustomobject]@{ addonsPath = "$box\AddOns"; flavor = 'forever'; curseforgeGameVersionTypeId = 88568; addons = @() }
    Save-Config $cfg

    # 1. WoWInterface lookups
    $l = Get-WowiLatest $cfg ([pscustomobject]@{ wowiId = 17996 })   # GTFO
    Assert ($l.version -and $l.url -match 'wowinterface') "WoWInterface returns a version and download for GTFO ($($l.version))"

    # 2. CurseForge still finds a normal (non early-access) Forever file
    $d = Get-CurseforgeLatest $cfg ([pscustomobject]@{ projectId = 61284 })
    Assert ($d.version) "CurseForge still finds Details ($($d.version))"

    # 3. Find my addons: fake folders for a WoWInterface-only addon, a known addon and an unknown one
    foreach ($f in 'GTFO', 'Pawn', 'NoSuchAddonXYZ') {
        New-Item -ItemType Directory "$box\AddOns\$f" | Out-Null
        "## Title: $f`n## Version: 0.0.1" | Set-Content "$box\AddOns\$f\$f.toc"
    }
    $found = @(Find-NewAddons $cfg)
    $g = $found | Where-Object { $_.entry.source -eq 'wowinterface' -and $_.entry.wowiId -eq 17996 }
    Assert $g 'scan offers GTFO from WoWInterface'
    Assert ($found | Where-Object { $_.name -eq 'Pawn' -and $_.entry.source -eq 'github' }) 'scan offers Pawn from the known list'
    Assert (-not ($found | Where-Object { $_.folders -contains 'NoSuchAddonXYZ' })) 'scan ignores an addon nobody publishes'

    # 4. Install GTFO for real into the fake folder; a folder it shipped "last time" but not now gets backed up
    $addon = $g.entry
    $addon | Add-Member -NotePropertyName folders -NotePropertyValue @('GTFO', 'GTFO_Retired') -Force
    $other = [pscustomobject]@{ name = 'Other'; source = 'github'; folder = 'SharedFolder'; hold = $false }
    $cfg.addons = @($addon, $other)
    New-Item -ItemType Directory "$box\AddOns\GTFO_Retired", "$box\AddOns\SharedFolder" | Out-Null
    $work = New-WorkFolder; $backup = Join-Path $box 'backup'
    $addon.folders += 'SharedFolder'   # claimed by another addon - must survive
    $names = Install-Addon $cfg $addon $l $work $backup
    Assert (Test-Path "$box\AddOns\GTFO\GTFO_Camelot.toc") 'GTFO installed from WoWInterface (with its Forever .toc)'
    Assert (-not (Test-Path "$box\AddOns\GTFO_Retired")) 'retired folder removed from AddOns'
    Assert (Test-Path "$backup\GTFO_Retired") 'retired folder kept in the backup'
    Assert (Test-Path "$box\AddOns\SharedFolder") "another addon's folder left alone"
    Assert (((Read-Config).addons | Where-Object { $_.wowiId -eq 17996 }).folders -join ',' -eq ($names -join ',')) 'installed folders recorded in addons.json'
    Remove-Item $work -Recurse -Force
    'ALL OK'
} finally {
    Remove-Item $box -Recurse -Force -ErrorAction SilentlyContinue
}
