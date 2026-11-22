# Shared logic for the WoW addon updater. Dot-sourced by Update-Addons.ps1 (console)
# and Addon-Updater.ps1 (window). Nothing here runs on its own.

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'

$script:Root        = $PSScriptRoot
$script:ConfigPath  = Join-Path $Root 'addons.json'
$script:StatePath   = Join-Path $Root 'state.json'
$script:BackupRoot  = Join-Path $Root 'backups'
$script:Headers     = @{ 'User-Agent' = 'wow-addon-updater' }
$script:KeepBackups = 3

$script:AppVersion = (Get-Content (Join-Path $Root 'VERSION') -ErrorAction SilentlyContinue | Select-Object -First 1)
$script:AppRepo    = 'imtehbst/grumpy-shark-updater'

# True only on the window's own thread (STA with WinForms loaded) - the console and the background worker never pump.
function Test-UiThread {
    [bool]('System.Windows.Forms.Application' -as [type]) -and [Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA'
}

# Web calls run async and this waits, pumping the window's messages so it never shows "Not responding".
# Errors come out as the original WebException.
function Wait-Task($task) {
    $ui = Test-UiThread
    while (-not $task.IsCompleted) { if ($ui) { [Windows.Forms.Application]::DoEvents() }; Start-Sleep -Milliseconds 30 }
    $task.GetAwaiter().GetResult()
}

# Runs slow core work (unzipping thousands of files, moving folders, scanning) on a background thread while the
# window keeps drawing; unzipping alone took 5-14 s per addon with the window frozen. Same process, so objects
# like $config and $state are shared, not copied. Outside the window it just runs the block directly.
$script:Worker = $null
function Invoke-Background([scriptblock]$block, [object[]]$argList = @()) {
    if (-not (Test-UiThread)) { return & $block @argList }
    if (-not $script:Worker) {
        $script:Worker = [runspacefactory]::CreateRunspace()
        $script:Worker.ApartmentState = 'MTA'   # so Test-UiThread is false in there
        $script:Worker.Open()
        $init = [PowerShell]::Create(); $init.Runspace = $script:Worker
        [void]$init.AddScript(". '$((Join-Path $Root 'UpdaterCore.ps1') -replace "'", "''")'; `$ErrorActionPreference = 'Stop'").Invoke()
        $init.Dispose()
    }
    $ps = [PowerShell]::Create(); $ps.Runspace = $script:Worker
    [void]$ps.AddScript($block.ToString())
    foreach ($a in $argList) { [void]$ps.AddArgument($a) }
    try {
        $h = $ps.BeginInvoke()
        while (-not $h.IsCompleted) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 30 }
        try { $ps.EndInvoke($h) }
        catch { throw $(if ($_.Exception.InnerException) { $_.Exception.InnerException } else { $_.Exception }) }
    } finally { $ps.Dispose() }
}

function New-WebClient {
    $w = New-Object Net.WebClient
    $w.Headers['User-Agent'] = $Headers['User-Agent']
    $w.Encoding = [Text.Encoding]::UTF8
    return $w
}

function Get-Json($url) { Wait-Task ((New-WebClient).DownloadStringTaskAsync($url)) | ConvertFrom-Json }

function Read-Config {
    # First run on a new PC: start with a blank list (addons.json is personal and not in the download).
    if (-not (Test-Path $ConfigPath)) {
        Write-FileRetry $ConfigPath (@{ addonsPath = ''; flavor = 'forever'; curseforgeGameVersionTypeId = 88568; addons = @() } | ConvertTo-Json)
    }
    $c = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    $c.addons = @($c.addons | Where-Object { $_ })   # PS 5.1 reads [] as $null
    return $c
}

# Returns @{ version; url } when GitHub has a newer Grumpy Shark Updater release, else $null. Never throws.
function Get-AppUpdate {
    try {
        $rel = Get-Json "https://api.github.com/repos/$AppRepo/releases/latest"
        $latest = $rel.tag_name -replace '^v', ''
        if ($AppVersion -and [version]$latest -gt [version]$AppVersion) { return @{ version = $latest; url = $rel.html_url } }
    } catch {}
    return $null
}

# Looks for <WoW>\_forever_\Interface\AddOns via Battle.net's registry entry, then common install spots.
function Find-AddonsPath($flavorDir = '_forever_') {
    $roots = @()
    foreach ($key in 'HKLM:\SOFTWARE\WOW6432Node\Blizzard Entertainment\World of Warcraft', 'HKLM:\SOFTWARE\Blizzard Entertainment\World of Warcraft') {
        $p = (Get-ItemProperty $key -ErrorAction SilentlyContinue).InstallPath
        if ($p) { $roots += (Split-Path $p.TrimEnd('\') -Parent) }   # InstallPath points at a flavor folder like _retail_
    }
    foreach ($d in (Get-PSDrive -PSProvider FileSystem).Root) {
        $roots += "${d}World of Warcraft", "${d}Program Files (x86)\World of Warcraft", "${d}Program Files\World of Warcraft", "${d}Games\World of Warcraft"
    }
    foreach ($r in $roots | Select-Object -Unique) {
        $a = Join-Path $r "$flavorDir\Interface\AddOns"
        if (Test-Path $a) { return $a }
    }
    return $null
}

function Write-FileRetry($path, $text) {
    # Antivirus/indexer can hold a just-written file for a moment; retry briefly.
    for ($i = 1; $i -le 10; $i++) {
        try { [IO.File]::WriteAllText($path, $text); return }
        catch [IO.IOException] { if ($i -eq 10) { throw }; Start-Sleep -Milliseconds 300 }
    }
}

function Save-Config($config) { Write-FileRetry $ConfigPath ($config | ConvertTo-Json -Depth 5) }

function Read-State {
    $s = @{}
    if (Test-Path $StatePath) {
        (Get-Content $StatePath -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $s[$_.Name] = $_.Value }
    }
    return $s
}

function Save-State($state) { Write-FileRetry $StatePath ($state | ConvertTo-Json) }

function Get-TocVersion($folder) {
    if (-not (Test-Path $folder)) { return $null }
    $lines = Get-ChildItem $folder -Filter *.toc -ErrorAction SilentlyContinue |
        Select-String -Pattern '^##\s*Version\s*:' | ForEach-Object { $_.Line.Trim() } | Sort-Object -Unique
    if (-not $lines) { return $null }
    return ($lines -join ' | ')
}

function Test-WowRunning {
    return [bool](Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^Wow(Classic|T|B)?$' })
}

function Get-GithubLatest($config, $addon) {
    $rel = Get-Json "https://api.github.com/repos/$($addon.repo)/releases/latest"
    $zips = @($rel.assets | Where-Object { $_.name -like '*.zip' })
    $asset = $null
    if ($addon.assetPattern) {
        $asset = $zips | Where-Object { $_.name -match $addon.assetPattern } | Select-Object -First 1
    } else {
        # Packager-built releases ship a release.json saying which zip suits which game flavor.
        $meta = $rel.assets | Where-Object { $_.name -eq 'release.json' } | Select-Object -First 1
        if ($meta) {
            $info = Get-Json $meta.browser_download_url
            $pick = $info.releases | Where-Object { -not $_.nolib -and ($_.metadata.flavor -contains $config.flavor) } | Select-Object -First 1
            if ($pick) { $asset = $zips | Where-Object { $_.name -eq $pick.filename } | Select-Object -First 1 }
        }
        # No release.json: prefer a zip named for this flavor (e.g. Pawn-2.14.7-Forever.zip), else the only/first zip.
        if (-not $asset) { $asset = $zips | Where-Object { $_.name -match $config.flavor -and $_.name -notmatch 'nolib' } | Select-Object -First 1 }
        if (-not $asset -and $zips.Count -gt 1 -and ($zips.name -match 'classic|wrath|cata|tbc|burningcrusade|pandaria|mists')) {
            throw "release has downloads for other game versions but none named for $($config.flavor)"
        }
        if (-not $asset) { $asset = $zips | Where-Object { $_.name -notmatch 'nolib' } | Select-Object -First 1 }
    }
    if (-not $asset) { throw "no $($config.flavor) zip in release $($rel.tag_name)" }
    return @{ version = $rel.tag_name; url = $asset.browser_download_url; file = $asset.name }
}

function Get-CurseforgeLatest($config, $addon) {
    # The site API ignores a game-version filter, so page through newest-first: busy addons upload many
    # Retail/Classic files between Forever ones (Details: 8 Forever files in its newest 50).
    # shortcut: looks at the newest 200 files only; raise the page count if an addon with a Forever file says it has none.
    $file = $null
    for ($page = 0; $page -lt 4 -and -not $file; $page++) {
        $list = Get-Json "https://www.curseforge.com/api/v1/mods/$($addon.projectId)/files?pageIndex=$page&pageSize=50&sort=dateCreated&sortDescending=true"
        $file = $list.data |
            Where-Object { $_.releaseType -eq 1 -and -not $_.isEarlyAccessContent -and ($_.gameVersionTypeIds -contains [int]$config.curseforgeGameVersionTypeId) } |
            Sort-Object { [datetime]$_.dateCreated } -Descending | Select-Object -First 1
        if (@($list.data).Count -lt 50) { break }
    }
    if (-not $file) { throw "no release file for $($config.flavor) on CurseForge" }
    $version = $file.displayName -replace '\.zip$', ''
    return @{ version = $version; url = "https://www.curseforge.com/api/v1/mods/$($addon.projectId)/files/$($file.id)/download"; file = $file.fileName }
}

# WoWInterface's public API (no key). Forever builds are tagged with game version 1.60.x.
function Get-WowiPrefix($config) { if ($config.wowinterfaceVersionPrefix) { $config.wowinterfaceVersionPrefix } else { '1.60.' } }

function Get-WowiLatest($config, $addon) {
    $d = @(Get-Json "https://api.mmoui.com/v4/game/WOW/filedetails/$($addon.wowiId).json")[0]
    if (-not $d -or -not $d.downloadUri) { throw 'not found on WoWInterface' }
    return @{ version = [string]$d.version; url = $d.downloadUri; file = $d.fileName }
}

# Folder name -> WoWInterface addon, for addons that list a Forever game version. One ~4 MB download per scan.
function Get-WowiForeverMap($config) {
    $map = @{}
    $prefix = Get-WowiPrefix $config
    try { $list = Get-Json 'https://api.mmoui.com/v4/game/WOW/filelist.json' } catch { return $map }
    foreach ($a in $list) {
        if (-not (@($a.gameVersions) | Where-Object { "$_".StartsWith($prefix) })) { continue }
        foreach ($p in @($a.addons)) { if ($p.path -and -not $map[$p.path]) { $map[$p.path] = $a } }
    }
    return $map
}

function Get-Latest($config, $addon) {
    switch ($addon.source) {
        'github'       { Get-GithubLatest $config $addon }
        'wowinterface' { Get-WowiLatest $config $addon }
        default        { Get-CurseforgeLatest $config $addon }
    }
}

function Expand-Release($latest, $work) {
    # The file name comes from a website: keep only the name part so it can't point outside the work folder.
    $name = [IO.Path]::GetFileName([string]$latest.file); if (-not $name) { $name = 'download.zip' }
    $zip = Join-Path $work $name
    $out = Join-Path $work ([IO.Path]::GetFileNameWithoutExtension($name))
    if (-not (Test-Path $out)) {
        $null = Wait-Task ((New-WebClient).DownloadFileTaskAsync($latest.url, $zip))   # its result is an empty value that would join the folder list
        Assert-SafeZip $zip
        [IO.Compression.ZipFile]::ExtractToDirectory($zip, $out)   # 3x faster than Expand-Archive; Assert-SafeZip loaded the assembly
    }
    $folders = @(Get-ChildItem $out -Directory)
    if (-not $folders) { throw 'download had no addon folders' }
    return $folders
}

# Refuses a zip whose entries climb out of the folder it's unpacked into (..\ or C:\ paths).
function Assert-SafeZip($zip) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $z = [IO.Compression.ZipFile]::OpenRead($zip)
    try {
        $bad = $z.Entries | Where-Object { $_.FullName -match '(^|[\\/])\.\.([\\/]|$)' -or $_.FullName -match '^([\\/]|[A-Za-z]:)' } | Select-Object -First 1
        if ($bad) { throw "download has an unsafe file path: $($bad.FullName)" }
    } finally { $z.Dispose() }
}

# Returns @{ status = 'current' | 'update' | 'error'; latest; folders; message }
# Downloads only when it must (first time an addon is seen, to compare TOC versions).
function Get-AddonStatus($config, $addon, $state, $work) {
    try { $latest = Get-Latest $config $addon }
    catch { return @{ status = 'error'; message = $_.Exception.Message } }

    $known = $state[$addon.name]
    if ($known -and $known -eq $latest.version) { return @{ status = 'current'; latest = $latest } }

    if (-not $known) {
        try { $folders = Expand-Release $latest $work }
        catch { return @{ status = 'error'; latest = $latest; message = $_.Exception.Message } }
        $same = $true
        foreach ($f in $folders) {
            $new = Get-TocVersion $f.FullName
            $old = Get-TocVersion (Join-Path $config.addonsPath $f.Name)
            if ($new -and $new -ne $old) { $same = $false; break }
        }
        if ($same) { return @{ status = 'current'; latest = $latest; firstSeen = $true } }
    }
    return @{ status = 'update'; latest = $latest }
}

# Installs one addon's latest release; old folders go into $backup. Returns the folder names.
function Install-Addon($config, $addon, $latest, $work, $backup) {
    $folders = Expand-Release $latest $work
    foreach ($f in $folders) {
        $target = Join-Path $config.addonsPath $f.Name
        $saved = Join-Path $backup $f.Name
        $moved = $false
        if (Test-Path $target) {
            New-Item -ItemType Directory $backup -Force | Out-Null
            if (Test-Path $saved) { Remove-Item $saved -Recurse -Force }
            Move-Item $target $saved -ErrorAction Stop
            $moved = $true
        }
        # If the new folder can't go in, put the old one back so the addon isn't left missing or half-installed.
        # (A failed Move-Item can leave a partial copy at $target, so clear that first.)
        try { Move-Item $f.FullName $target -ErrorAction Stop }
        catch {
            if (Test-Path $target) { Remove-Item $target -Recurse -Force }
            if ($moved) { Move-Item $saved $target }
            throw
        }
    }

    # Folders this addon installed last time but no longer ships: move them to the backup too (undo brings them back).
    # Only folders recorded from our own earlier install, and never one another tracked addon claims.
    $new = @($folders.Name)
    $others = @($config.addons | Where-Object { $_.name -ne $addon.name } | ForEach-Object { $_.folder; $_.folders } | Where-Object { $_ })
    foreach ($old in @($addon.folders | Where-Object { $_ })) {
        $path = Join-Path $config.addonsPath $old
        if ($new -notcontains $old -and $others -notcontains $old -and (Test-Path $path)) {
            New-Item -ItemType Directory $backup -Force | Out-Null
            Move-Item $path (Join-Path $backup $old) -Force
        }
    }
    $addon | Add-Member -NotePropertyName folders -NotePropertyValue $new -Force
    Save-Config $config
    return $new
}

function Remove-OldBackups {
    Get-ChildItem $BackupRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending |
        Select-Object -Skip $KeepBackups | Remove-Item -Recurse -Force
}

# Puts the newest backup's folders back. Returns the folder names restored (empty if no backup).
function Restore-LastBackup($config) {
    $last = Get-ChildItem $BackupRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
    if (-not $last) { return @() }
    $names = @()
    foreach ($dir in Get-ChildItem $last.FullName -Directory) {
        $target = Join-Path $config.addonsPath $dir.Name
        if (Test-Path $target) { Remove-Item $target -Recurse -Force }
        Move-Item $dir.FullName $target
        $names += $dir.Name
    }
    Remove-Item $last.FullName -Recurse -Force
    Remove-Item $StatePath -ErrorAction SilentlyContinue   # next check re-reads versions from the TOC files
    return $names
}

# ---------- Find my addons ----------

function Get-TocField($folder, $field) {
    # Prefer the Forever .toc (Questie's plain .toc says "game client not supported").
    $hit = Get-ChildItem $folder -Filter *.toc -ErrorAction SilentlyContinue |
        Sort-Object { $_.Name -notmatch 'forever|camelot' } |
        Select-String -Pattern "^##\s*$([regex]::Escape($field))\s*:\s*(.+)$" | Select-Object -First 1
    if ($hit) { return $hit.Matches[0].Groups[1].Value.Trim() }
}

# "|cff308530Voicepack|r" -> "Voicepack"
function Format-TocTitle($t) { ($t -replace '\|c[0-9a-fA-F]{8}', '' -replace '\|r', '' -replace '\|T[^|]*\|t', '').Trim() }

function Test-CurseforgeHasFlavor($config, $projectId) {
    try { Get-CurseforgeLatest $config @{ projectId = $projectId } | Out-Null; return $true } catch { return $false }
}

# Scans the AddOns folder for addons that aren't tracked yet. Matches folders against known-addons.json
# first (prefers GitHub sources), then any folder whose .toc names a CurseForge project.
# Returns candidates: @{ name; entry (to add to addons.json); folders; available; why }
function Find-NewAddons($config) {
    $known = @()
    $knownPath = Join-Path $Root 'known-addons.json'
    if (Test-Path $knownPath) { $known = Get-Content $knownPath -Raw | ConvertFrom-Json; $known = @($known) }   # two steps: PS 5.1 pipes a JSON array as one item

    $trackedNames = @($config.addons | ForEach-Object { $_.name })
    $trackedIds   = @($config.addons | ForEach-Object { $_.projectId; $_.curseId } | Where-Object { $_ } | ForEach-Object { [string]$_ })
    $trackedWowi  = @($config.addons | ForEach-Object { $_.wowiId } | Where-Object { $_ } | ForEach-Object { [string]$_ })
    $trackedDirs  = @($config.addons | ForEach-Object { $_.folder; $_.folders } | Where-Object { $_ })
    $wowi = Get-WowiForeverMap $config

    $found = [ordered]@{}
    foreach ($dir in Get-ChildItem $config.addonsPath -Directory) {
        if ($trackedDirs -contains $dir.Name) { continue }
        $cid = Get-TocField $dir.FullName 'X-Curse-Project-ID'
        # curseId may be a list: one download can hold folders from several CurseForge projects.
        $k = $known | Where-Object { $_.folder -eq $dir.Name -or ($cid -and (@($_.curseId) | ForEach-Object { [string]$_ }) -contains $cid) } | Select-Object -First 1
        if ($k) {
            if ($trackedNames -contains $k.name -or (@($k.curseId) | Where-Object { $_ -and $trackedIds -contains [string]$_ })) { continue }
            $key = "known:$($k.name)"
            if (-not $found[$key]) { $found[$key] = @{ name = $k.name; entry = $k; folders = @(); available = $true; why = 'known source' } }
        } elseif ($cid) {
            if ($trackedIds -contains $cid) { continue }
            $key = "cf:$cid"
            if (-not $found[$key]) {
                $found[$key] = @{ name = ''; entry = [pscustomobject]@{ source = 'curseforge'; projectId = [int]$cid; folder = $dir.Name }; folders = @(); why = 'CurseForge' }
            }
        } elseif ($wowi[$dir.Name]) {
            $w = $wowi[$dir.Name]
            if ($trackedWowi -contains [string]$w.id) { continue }
            $key = "wowi:$($w.id)"
            if (-not $found[$key]) { $found[$key] = @{ name = $w.title; entry = (New-WowiEntry $w); folders = @(); available = $true; why = 'WoWInterface' } }
        } else { continue }
        $found[$key].folders += $dir.Name
    }

    foreach ($c in $found.Values) {
        if ($c.why -eq 'CurseForge') {
            # Name it after the shortest folder in the group (the main addon, not its plugins).
            $main = $c.folders | Sort-Object Length | Select-Object -First 1
            $title = Format-TocTitle (Get-TocField (Join-Path $config.addonsPath $main) 'Title')
            $c.name = if ($title) { $title } else { $main }
            $c.entry.folder = $main
            $c.available = Test-CurseforgeHasFlavor $config $c.entry.projectId
            # No Forever file on CurseForge? WoWInterface may have one.
            $w = $wowi[$main]
            if (-not $c.available -and $w -and $trackedWowi -notcontains [string]$w.id) {
                $c.name = $w.title; $c.entry = New-WowiEntry $w; $c.available = $true; $c.why = 'WoWInterface'
            }
        }
        $c.entry = [pscustomobject]@{} | Add-Member -PassThru -NotePropertyMembers (@{ name = $c.name; hold = $false } + (ConvertTo-Hash $c.entry))
    }
    return @($found.Values)
}

function New-WowiEntry($w) {
    $main = @($w.addons.path) | Sort-Object Length | Select-Object -First 1
    return [pscustomobject]@{ source = 'wowinterface'; wowiId = [int]$w.id; folder = $main }
}

function ConvertTo-Hash($obj) {
    $h = @{}
    $obj.PSObject.Properties | Where-Object { $_.Name -notin 'name', 'hold' } | ForEach-Object { $h[$_.Name] = $_.Value }
    return $h
}

# Adds a GitHub repo by link (github.com/owner/repo). Returns the new entry, or throws if it has no usable release.
function New-GithubEntry($config, $link) {
    if ($link -notmatch 'github\.com/([^/\s]+)/([^/\s#?]+)') { throw 'That is not a GitHub repo link.' }
    $repo = "$($Matches[1])/$($Matches[2] -replace '\.git$', '')"
    $entry = [pscustomobject]@{ name = ($repo -split '/')[1]; source = 'github'; repo = $repo; folder = ($repo -split '/')[1]; hold = $false }
    try { $latest = Get-GithubLatest $config $entry }
    catch [Net.WebException] { throw "$repo has no published releases to download." }
    if ($latest.file -match $config.flavor) { $entry | Add-Member -NotePropertyName assetPattern -NotePropertyValue "-$($config.flavor)\.zip$" }
    return $entry
}

function New-WorkFolder {
    $w = Join-Path $env:TEMP ('wow-updater-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory $w | Out-Null
    return $w
}

function New-BackupPath { Join-Path $BackupRoot (Get-Date -Format 'yyyy-MM-dd_HHmmss') }
