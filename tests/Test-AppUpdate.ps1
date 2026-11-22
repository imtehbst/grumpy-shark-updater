# Self-check for "click to update": an old copy updates itself from the latest GitHub release without touching
# the player's own files. Works in a throwaway copy. Needs internet.
# Run: powershell -ExecutionPolicy Bypass -File tests\Test-AppUpdate.ps1
$ErrorActionPreference = 'Stop'
$src = Split-Path $PSScriptRoot -Parent
$box = Join-Path $env:TEMP ('gsu-app-' + [guid]::NewGuid().ToString('N'))
function Assert($ok, $msg) { if (-not $ok) { throw "FAIL: $msg" }; "ok   $msg" }

try {
    # an old install as a friend has it: program files, plus their own list, state, backups and art
    New-Item -ItemType Directory "$box\art", "$box\backups\2026-01-01_000000\SomeAddon" | Out-Null
    Copy-Item "$src\UpdaterCore.ps1", "$src\Addon-Updater.ps1" $box
    '1.0.0' | Set-Content "$box\VERSION"
    '{"addonsPath":"X:\\AddOns","addons":[{"name":"Mine"}]}' | Set-Content "$box\addons.json"
    '{"Mine":"1"}' | Set-Content "$box\state.json"
    'my art' | Set-Content "$box\art\personal.png"
    $before = Get-Content "$box\addons.json" -Raw

    . "$box\UpdaterCore.ps1"
    $u = Get-AppUpdate
    Assert ($u -and $u.zip) "a 1.0.0 copy sees release $($u.version)"
    Install-AppUpdate $u $box
    Assert ((Get-Content "$box\VERSION" -Raw).Trim() -eq $u.version) "VERSION now says $($u.version)"
    Assert (Test-Path "$box\art\grumpy-shark.ico") 'program art arrived'
    Assert (-not (Test-Path "$box\art\art")) 'art copied into place, not nested'
    Assert ((Get-Content "$box\addons.json" -Raw) -eq $before) 'addons.json untouched'
    Assert ((Test-Path "$box\state.json") -and (Test-Path "$box\art\personal.png") -and (Test-Path "$box\backups\2026-01-01_000000\SomeAddon")) 'state, own art and backups untouched'

    New-Item -ItemType Directory "$box\.git" | Out-Null
    try { Install-AppUpdate $u $box; $refused = $false } catch { $refused = $true }
    Assert $refused 'a git clone is left for git to update'
    'ALL OK'
} finally {
    Remove-Item $box -Recurse -Force -ErrorAction SilentlyContinue
}
