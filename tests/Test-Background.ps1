# Self-check for the window's background worker: a real download + unzip + install into a fake AddOns folder
# must keep the window thread pumping, share objects with the window, and pass errors back.
# Run: powershell -STA -ExecutionPolicy Bypass -File tests\Test-Background.ps1   (needs internet)
$ErrorActionPreference = 'Stop'
$src = Split-Path $PSScriptRoot -Parent
$box = Join-Path $env:TEMP ('gsu-bg-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory "$box\app", "$box\AddOns" | Out-Null
Copy-Item "$src\UpdaterCore.ps1" "$box\app"
function Assert($ok, $msg) { if (-not $ok) { throw "FAIL: $msg" }; "ok   $msg" }

try {
    Add-Type -AssemblyName System.Windows.Forms
    . "$box\app\UpdaterCore.ps1"
    Assert (Test-UiThread) 'this thread counts as the window thread'
    $cfg = [pscustomobject]@{ addonsPath = "$box\AddOns"; flavor = 'forever'; curseforgeGameVersionTypeId = 88568; addons = @() }
    $addon = [pscustomobject]@{ name = 'Questie'; source = 'github'; repo = 'Questie/Questie'; folder = 'QuestieDB'; hold = $false }
    $cfg.addons = @($addon); Save-Config $cfg

    # count message-pump ticks while the worker runs: a frozen window would get none
    $script:ticks = 0
    $timer = New-Object Windows.Forms.Timer; $timer.Interval = 100; $timer.add_Tick({ $script:ticks++ }); $timer.Start()
    $work = New-WorkFolder
    $l = Invoke-Background { param($c, $a) Get-Latest $c $a } @($cfg, $addon)
    $t = Measure-Command { $names = @(Invoke-Background { param($c, $a, $l, $w, $b) Install-Addon $c $a $l $w $b } @($cfg, $addon, $l, $work, "$box\backup")) }
    $timer.Stop()
    Assert ($names.Count -gt 0 -and (Test-Path "$box\AddOns\$($names[0])")) "Questie installed in the background ($($names.Count) folders, $([int]$t.TotalSeconds) s)"
    Assert ($script:ticks -ge [int]($t.TotalMilliseconds / 100 * 0.5)) "window kept ticking while it worked ($script:ticks ticks)"
    Assert (@($addon.folders).Count -eq $names.Count) 'background changes show up on the same addon object'

    $r = Invoke-Background { param($c, $a, $s, $w) Get-AddonStatus $c $a $s $w } @($cfg, $addon, @{ Questie = $l.version }, $work)
    $r.status = 'done'
    Assert ($r.status -eq 'done') 'status from the worker can be updated by the window'

    try { Invoke-Background { throw 'boom' }; $msg = '' } catch { $msg = $_.Exception.Message }
    Assert ($msg -eq 'boom') "errors come back with their own message ('$msg')"
    Remove-Item $work -Recurse -Force
    'ALL OK'
} finally {
    Remove-Item $box -Recurse -Force -ErrorAction SilentlyContinue
}
