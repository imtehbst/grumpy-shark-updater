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
        $rel = Invoke-RestMethod "https://api.github.com/repos/$AppRepo/releases/latest" -Headers $Headers
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
    return [bool](Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^Wow' })
}

function Get-GithubLatest($config, $addon) {
    $rel = Invoke-RestMethod "https://api.github.com/repos/$($addon.repo)/releases/latest" -Headers $Headers
    $zips = @($rel.assets | Where-Object { $_.name -like '*.zip' })
    $asset = $null
    if ($addon.assetPattern) {
        $asset = $zips | Where-Object { $_.name -match $addon.assetPattern } | Select-Object -First 1
    } else {
        # Packager-built releases ship a release.json saying which zip suits which game flavor.
        $meta = $rel.assets | Where-Object { $_.name -eq 'release.json' } | Select-Object -First 1
        if ($meta) {
            $info = Invoke-RestMethod $meta.browser_download_url -Headers $Headers
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
    $list = Invoke-RestMethod "https://www.curseforge.com/api/v1/mods/$($addon.projectId)/files?pageIndex=0&pageSize=30&sort=dateCreated&sortDescending=true" -Headers $Headers
    $file = $list.data |
        Where-Object { $_.releaseType -eq 1 -and -not $_.isEarlyAccessContent -and ($_.gameVersionTypeIds -contains [int]$config.curseforgeGameVersionTypeId) } |
        Sort-Object { [datetime]$_.dateCreated } -Descending | Select-Object -First 1
    if (-not $file) { throw "no release file for $($config.flavor) on CurseForge" }
    $version = $file.displayName -replace '\.zip$', ''
    return @{ version = $version; url = "https://www.curseforge.com/api/v1/mods/$($addon.projectId)/files/$($file.id)/download"; file = $file.fileName }
}

# WoWInterface's public API (no key). Forever builds are tagged with game version 1.60.x.
function Get-WowiPrefix($config) { if ($config.wowinterfaceVersionPrefix) { $config.wowinterfaceVersionPrefix } else { '1.60.' } }

function Get-WowiLatest($config, $addon) {
    $d = @(Invoke-RestMethod "https://api.mmoui.com/v4/game/WOW/filedetails/$($addon.wowiId).json" -Headers $Headers)[0]
    if (-not $d -or -not $d.downloadUri) { throw 'not found on WoWInterface' }
    return @{ version = [string]$d.version; url = $d.downloadUri; file = $d.fileName }
}

# Folder name -> WoWInterface addon, for addons that list a Forever game version. One ~4 MB download per scan.
function Get-WowiForeverMap($config) {
    $map = @{}
    $prefix = Get-WowiPrefix $config
    try { $list = Invoke-RestMethod 'https://api.mmoui.com/v4/game/WOW/filelist.json' -Headers $Headers } catch { return $map }
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
    $zip = Join-Path $work $latest.file
    $out = Join-Path $work ([IO.Path]::GetFileNameWithoutExtension($latest.file))
    if (-not (Test-Path $out)) {
        Invoke-WebRequest $latest.url -OutFile $zip -Headers $Headers -UseBasicParsing
        Expand-Archive $zip -DestinationPath $out -Force
    }
    $folders = @(Get-ChildItem $out -Directory)
    if (-not $folders) { throw 'download had no addon folders' }
    return $folders
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
        if (Test-Path $target) {
            New-Item -ItemType Directory $backup -Force | Out-Null
            if (Test-Path (Join-Path $backup $f.Name)) { Remove-Item (Join-Path $backup $f.Name) -Recurse -Force }
            Move-Item $target (Join-Path $backup $f.Name)
        }
        Move-Item $f.FullName $target
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
