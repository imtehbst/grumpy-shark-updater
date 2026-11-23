# Self-check (offline): a failed install puts back EVERY folder of a multi-folder addon, and Undo switches
# the restored addon's updates off. Works in a throwaway folder - never touches the real AddOns.
# Run: powershell -ExecutionPolicy Bypass -File tests\Test-Rollback.ps1
$ErrorActionPreference = 'Stop'
$src = Split-Path $PSScriptRoot -Parent
$box = Join-Path $env:TEMP ('gsu-rb-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory "$box\app\backups", "$box\AddOns" | Out-Null
Copy-Item "$src\UpdaterCore.ps1" "$box\app"
function Assert($ok, $msg) { if (-not $ok) { throw "FAIL: $msg" }; "ok   $msg" }

try {
    . "$box\app\UpdaterCore.ps1"
    $addon = [pscustomobject]@{ name = 'Multi'; source = 'github'; folder = 'MultiA'; hold = $false }
    $cfg = [pscustomobject]@{ addonsPath = "$box\AddOns"; flavor = 'forever'; addons = @($addon) }
    Save-Config $cfg
    foreach ($f in 'MultiA', 'MultiB') {
        New-Item -ItemType Directory "$box\AddOns\$f" | Out-Null
        '## Version: old' | Set-Content "$box\AddOns\$f\$f.toc"
    }
    # A release zip holding new copies of both folders, "downloaded" from a file:// link.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = Join-Path $box 'Multi-2.zip'
    $z = [IO.Compression.ZipFile]::Open($zip, 'Create')
    foreach ($f in 'MultiA', 'MultiB') {
        $w = New-Object IO.StreamWriter($z.CreateEntry("$f/$f.toc").Open()); $w.Write('## Version: new'); $w.Dispose()
    }
    $z.Dispose()
    $latest = @{ version = '2'; url = ([uri]$zip).AbsoluteUri; file = 'Multi-2.zip' }

    # 1. MultiA goes in, MultiB can't (a file in it is held open): both must end up old again.
    $work = New-WorkFolder
    $ready = Expand-Release $latest $work
    $lock = [IO.File]::Open((Join-Path ($ready | Where-Object Name -eq 'MultiB').FullName 'MultiB.toc'), 'Open', 'Read', 'None')
    try { Install-Addon $cfg $addon $latest $work (Join-Path $box 'app\backups\1') | Out-Null; $threw = $false } catch { $threw = $true } finally { $lock.Dispose() }
    Assert $threw 'install reports the failure'
    Assert ((Get-Content "$box\AddOns\MultiA\MultiA.toc") -match 'old') 'MultiA put back to the old version too'
    Assert ((Get-Content "$box\AddOns\MultiB\MultiB.toc") -match 'old') 'MultiB kept the old version'

    # 2. A working install, then Undo: old versions back and the addon's updates switched off.
    Remove-Item $work -Recurse -Force; $work = New-WorkFolder
    Install-Addon $cfg $addon $latest $work (Join-Path $box 'app\backups\2') | Out-Null
    Assert ((Get-Content "$box\AddOns\MultiB\MultiB.toc") -match 'new') 'normal install works'
    Get-ChildItem "$box\app\backups" -Directory | Where-Object { -not (Get-ChildItem $_.FullName) } | Remove-Item
    $names = Restore-LastBackup $cfg
    Assert (($names -contains 'MultiA') -and ((Get-Content "$box\AddOns\MultiA\MultiA.toc") -match 'old')) 'undo puts the old version back'
    Assert ((Read-Config).addons[0].hold -eq $true) "undo switches the addon's updates off"
    Remove-Item $work -Recurse -Force
    'ALL OK'
} finally {
    Remove-Item $box -Recurse -Force -ErrorAction SilentlyContinue
}
