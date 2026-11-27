# Self-check: a site that accepts the connection but never answers is given up on with a clear error.
# Uses a local listener that never replies; never touches the real AddOns folder.
. (Join-Path $PSScriptRoot '..\UpdaterCore.ps1')
$ErrorActionPreference = 'Stop'
$fail = 0
function Check($ok, $what) { if ($ok) { "ok   $what" } else { "FAIL $what"; $script:fail++ } }

$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $listener.Start()
$port = $listener.LocalEndpoint.Port
$script:WebTimeoutSec = 3
try {
    $sw = [Diagnostics.Stopwatch]::StartNew(); $msg = ''
    try { Get-Json "http://127.0.0.1:$port/never" | Out-Null } catch { $msg = $_.Exception.Message }
    Check ($msg -like '*stopped answering*') "a silent site gives a clear error ('$msg')"
    Check ($sw.Elapsed.TotalSeconds -lt 10) "it gives up in about 3 s ($([int]$sw.Elapsed.TotalSeconds) s)"

    $zip = Join-Path ([IO.Path]::GetTempPath()) "gs-timeout-$port.zip"; $msg = ''
    $c = New-WebClient
    try { $null = Wait-Task $c.DownloadFileTaskAsync("http://127.0.0.1:$port/file.zip", $zip) $c $zip } catch { $msg = $_.Exception.Message }
    Check ($msg -like '*stopped answering*') 'a stalled download gives the same error'
    Remove-Item $zip -ErrorAction SilentlyContinue
} finally { $listener.Stop() }
if ($fail) { "$fail FAILED"; exit 1 } else { 'ALL OK' }
