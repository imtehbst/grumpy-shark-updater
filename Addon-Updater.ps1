<#
  Addon-Updater.ps1 - Grumpy Shark Addon Updater (window version).
  Tick "Update" to let an addon update; untick to keep it on the version you have.
  -Screenshot <png> : check, save a picture of the window, and close (used for previews).
#>
param([string]$Screenshot, [switch]$FindShot)   # -FindShot: also open Find my addons, save its picture, press "Add ticked"

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'UpdaterCore.ps1')
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

$config  = Read-Config
$state   = Read-State
$results = @{}   # addon name -> status from the last check
$work    = New-WorkFolder   # kept all session so Update reuses what Check downloaded; removed on close
$art     = Join-Path $PSScriptRoot 'art'

# ---------- ocean colours (same family as Fins & Fangs) ----------
function C($hex) { [Drawing.ColorTranslator]::FromHtml($hex) }
$deep    = C '#061a2c'
$sea     = C '#07223a'
$panel   = C '#0b2f4d'
$rowAlt  = C '#0d3556'
$head    = C '#0e3a5e'
$pick    = C '#12476f'
$foam    = C '#e6f6ff'
$muted   = C '#8fb8cf'
$aqua    = C '#4fd8ff'
$kelp    = C '#3ddc97'
$coral   = C '#ff7a59'
$blood   = C '#ff5a6e'
$btnDark = C '#134a70'
$font    = New-Object Drawing.Font('Segoe UI', 10)
$bold    = New-Object Drawing.Font('Segoe UI Semibold', 10)

# ---------- window ----------
$form = New-Object Windows.Forms.Form
$form.Text = 'Grumpy Shark Addon Updater'
$form.Size = New-Object Drawing.Size(880, 600)
$form.MinimumSize = New-Object Drawing.Size(720, 480)
$form.StartPosition = 'CenterScreen'
$form.BackColor = $sea
$form.ForeColor = $foam
$form.Font = $font
$iconFile = Join-Path $art 'grumpy-shark.ico'
if (Test-Path $iconFile) { $form.Icon = New-Object Drawing.Icon($iconFile) }

# ---------- header: ocean picture + grumpy mascot ----------
$header = New-Object Windows.Forms.Panel
$header.Dock = 'Top'
$header.Height = 112
$header.BackColor = $deep
# Drawn, not a picture, so it stays clean at any window size: deep navy fading to sea blue, glowing aqua edge.
$header.add_Paint({
    param($s, $e)
    $r = $header.ClientRectangle
    if ($r.Width -lt 1) { return }
    $g = New-Object Drawing.Drawing2D.LinearGradientBrush($r, (C '#04121f'), (C '#0b3d63'), 0.0)
    $e.Graphics.FillRectangle($g, $r)
    $e.Graphics.FillRectangle((New-Object Drawing.SolidBrush((C '#4fd8ff'))), 0, $r.Height - 3, $r.Width, 3)
    $e.Graphics.FillRectangle((New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(70, 79, 216, 255))), 0, $r.Height - 8, $r.Width, 5)
})
$header.add_Resize({ $header.Invalidate() })

$mascot = New-Object Windows.Forms.PictureBox
$mascot.Size = New-Object Drawing.Size(96, 96)
$mascot.Location = New-Object Drawing.Point(14, 8)
$mascot.SizeMode = 'Zoom'
$mascot.BackColor = [Drawing.Color]::Transparent
$pngFile = Join-Path $art 'icon.png'
if (Test-Path $pngFile) { $mascot.Image = [Drawing.Image]::FromFile($pngFile) }
$header.Controls.Add($mascot)

$title = New-Object Windows.Forms.Label
$title.Text = 'Grumpy Shark Addon Updater'
$title.Font = New-Object Drawing.Font('Segoe UI Black', 18)
$title.ForeColor = $foam
$title.BackColor = [Drawing.Color]::Transparent
$title.AutoSize = $true
$title.Location = New-Object Drawing.Point(120, 22)
$header.Controls.Add($title)

$tag = New-Object Windows.Forms.Label
$tag.Text = 'Keeps your WoW Forever addons fresh. Grumbles about it.'
$tag.ForeColor = C '#bdefff'
$tag.BackColor = [Drawing.Color]::Transparent
$tag.AutoSize = $true
$tag.Location = New-Object Drawing.Point(124, 62)
$header.Controls.Add($tag)

# "New version available" link, shown only when GitHub has a newer release.
$newVer = New-Object Windows.Forms.LinkLabel
$newVer.AutoSize = $true
$newVer.Anchor = 'Top, Right'
$newVer.BackColor = [Drawing.Color]::Transparent
$newVer.LinkColor = $coral; $newVer.ActiveLinkColor = $foam
$newVer.Font = $bold
$newVer.Visible = $false
$header.Controls.Add($newVer)
if ($AppVersion) { $form.Text += " v$AppVersion" }

# ---------- AddOns folder row ----------
$folderLbl = New-Object Windows.Forms.Label
$folderLbl.AutoSize = $false
$folderLbl.Location = New-Object Drawing.Point(16, 124)
$folderLbl.Size = New-Object Drawing.Size(550, 24)
$folderLbl.Anchor = 'Top, Left, Right'
$folderLbl.ForeColor = $muted
$folderLbl.TextAlign = 'MiddleLeft'
$form.Controls.Add($folderLbl)

$btnFolder = New-Object Windows.Forms.Button
$btnFolder.Text = 'Change folder'
$btnFolder.Size = New-Object Drawing.Size(130, 28)
$btnFolder.Location = New-Object Drawing.Point(718, 122)
$btnFolder.Anchor = 'Top, Right'
$btnFolder.FlatStyle = 'Flat'
$btnFolder.FlatAppearance.BorderColor = $aqua
$btnFolder.ForeColor = $aqua
$btnFolder.BackColor = $sea
$btnFolder.Cursor = 'Hand'
$form.Controls.Add($btnFolder)

$btnFind = New-Object Windows.Forms.Button
$btnFind.Text = 'Find my addons'
$btnFind.Size = New-Object Drawing.Size(140, 28)
$btnFind.Location = New-Object Drawing.Point(570, 122)
$btnFind.Anchor = 'Top, Right'
$btnFind.FlatStyle = 'Flat'
$btnFind.FlatAppearance.BorderColor = $aqua
$btnFind.ForeColor = $aqua
$btnFind.BackColor = $sea
$btnFind.Cursor = 'Hand'
$form.Controls.Add($btnFind)

# ---------- grid ----------
$grid = New-Object Windows.Forms.DataGridView
$grid.Location = New-Object Drawing.Point(16, 158)
$grid.Size = New-Object Drawing.Size(832, 330)
$grid.Anchor = 'Top, Bottom, Left, Right'
$grid.BackgroundColor = $panel
$grid.BorderStyle = 'None'
$grid.GridColor = $sea
$grid.CellBorderStyle = 'SingleHorizontal'
$grid.RowHeadersVisible = $false
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.AllowUserToResizeRows = $false
$grid.SelectionMode = 'FullRowSelect'
$grid.MultiSelect = $false
$grid.AutoSizeColumnsMode = 'Fill'
$grid.ColumnHeadersHeightSizeMode = 'DisableResizing'
$grid.ColumnHeadersHeight = 34
$grid.RowTemplate.Height = 32
$grid.EnableHeadersVisualStyles = $false
$grid.ColumnHeadersBorderStyle = 'None'
$grid.ColumnHeadersDefaultCellStyle.BackColor = $head
$grid.ColumnHeadersDefaultCellStyle.ForeColor = $aqua
$grid.ColumnHeadersDefaultCellStyle.Font = $bold
$grid.ColumnHeadersDefaultCellStyle.SelectionBackColor = $head
$grid.DefaultCellStyle.BackColor = $panel
$grid.DefaultCellStyle.ForeColor = $foam
$grid.AlternatingRowsDefaultCellStyle.BackColor = $rowAlt
$grid.DefaultCellStyle.SelectionBackColor = $pick
$grid.DefaultCellStyle.SelectionForeColor = $foam
$grid.DefaultCellStyle.Padding = New-Object Windows.Forms.Padding(6, 0, 6, 0)

$colOn = New-Object Windows.Forms.DataGridViewCheckBoxColumn
$colOn.HeaderText = 'Update'; $colOn.FillWeight = 12; $colOn.Name = 'On'
[void]$grid.Columns.Add($colOn)
foreach ($c in @(@('Addon', 34), @('Installed', 22), @('Latest', 22), @('Status', 30))) {
    $col = New-Object Windows.Forms.DataGridViewTextBoxColumn
    $col.HeaderText = $c[0]; $col.Name = $c[0]; $col.FillWeight = $c[1]; $col.ReadOnly = $true
    [void]$grid.Columns.Add($col)
}
$grid.Columns['Addon'].DefaultCellStyle.Font = $bold
$form.Controls.Add($grid)

# ---------- bottom bar ----------
function New-Button($label, $x, $primary) {
    $b = New-Object Windows.Forms.Button
    $b.Text = $label
    $b.Size = New-Object Drawing.Size(160, 38)
    $b.Location = New-Object Drawing.Point($x, 502)
    $b.Anchor = 'Bottom, Left'
    # Styles' button look: dark navy with a glowing aqua edge.
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = if ($primary) { 2 } else { 1 }
    $b.FlatAppearance.BorderColor = if ($primary) { $aqua } else { C '#3a8fbf' }
    $b.BackColor = C '#0f3354'
    $b.ForeColor = if ($primary) { $aqua } else { $foam }
    $b.Font = $bold
    $b.Cursor = 'Hand'
    $form.Controls.Add($b)
    return $b
}
$btnCheck  = New-Button 'Check for updates' 16 $false
$btnUpdate = New-Button 'Update now' 186 $true
$btnUndo   = New-Button 'Undo last update' 356 $false

$status = New-Object Windows.Forms.Label
$status.AutoSize = $false
$status.Size = New-Object Drawing.Size(320, 38)
$status.Location = New-Object Drawing.Point(528, 502)
$status.Anchor = 'Bottom, Left, Right'
$status.TextAlign = 'MiddleRight'
$status.ForeColor = $muted
$form.Controls.Add($status)
$form.Controls.Add($header)

# ---------- helpers ----------
# "Plater-v664" -> "v664", "bundle/v12.11.1+v1.1.3" -> "v12.11.1+v1.1.3", "DungeonJournal2.1.0" -> "2.1.0"
function Format-Version($v) { if (-not $v) { return $v }; return ($v -replace '^[^\d]*?(?=[vr]?\d)', '') }

function Show-Folder {
    $ok = $config.addonsPath -and (Test-Path $config.addonsPath)
    $folderLbl.Text = if ($ok) { "AddOns folder:  $($config.addonsPath)" } else { 'AddOns folder not found - click Change folder' }
    $folderLbl.ForeColor = if ($ok) { $muted } else { $coral }
    return $ok
}

function Set-AddonsPath($path) {
    $config | Add-Member -NotePropertyName addonsPath -NotePropertyValue $path -Force
    Save-Config $config
    Show-Folder | Out-Null
}

function Get-InstalledText($addon) {
    if ($state[$addon.name]) { return (Format-Version $state[$addon.name]) }
    if (-not $config.addonsPath) { return '' }
    $v = Get-TocVersion (Join-Path $config.addonsPath $addon.folder)
    if ($v) { return (Format-Version (($v -split ' \| ')[0] -replace '^##\s*Version\s*:\s*', '' -replace '\s*\[.*$', '')) }
    return 'not installed'
}

function Set-RowStatus($row) {
    $addon = $config.addons[$row.Index]
    $r = $results[$addon.name]
    $cell = $row.Cells['Status']
    $row.Cells['Installed'].Value = Get-InstalledText $addon
    $cell.ToolTipText = if ($r -and $r.message) { $r.message } else { '' }   # hover a red row to see why
    if (-not $r) { $cell.Value = ''; return }
    $row.Cells['Latest'].Value = if ($r.latest) { Format-Version $r.latest.version } else { '-' }
    switch ($r.status) {
        'current' { $cell.Value = 'Up to date';      $cell.Style.ForeColor = $kelp }
        'error'   { $cell.Value = "Couldn't check";  $cell.Style.ForeColor = $blood }
        'failed'  { $cell.Value = 'Update failed (hover for why)'; $cell.Style.ForeColor = $blood }
        'update'  {
            if ($addon.hold) { $cell.Value = 'Update off (new version out)'; $cell.Style.ForeColor = $muted }
            else             { $cell.Value = 'Update available';             $cell.Style.ForeColor = $coral }
        }
        'done'    { $cell.Value = 'Updated';         $cell.Style.ForeColor = $kelp }
    }
}

function Update-Summary {
    $n = @($config.addons | Where-Object { -not $_.hold -and $results[$_.name].status -eq 'update' }).Count
    # Never set Enabled = $false: Windows then draws the text dark grey, unreadable on navy.
    $script:pending = $n
    $btnUpdate.FlatAppearance.BorderColor = if ($n) { $aqua } else { C '#3a8fbf' }
    $btnUpdate.ForeColor = if ($n) { $aqua } else { $muted }
    $btnUpdate.Text = if ($n) { "Update now ($n)" } else { 'Nothing to update' }
}

function Set-Busy($busy, $msg) {
    $script:busy = $busy   # buttons ignore clicks while busy instead of greying out
    $status.ForeColor = $muted
    $status.Text = $msg
    $form.Cursor = if ($busy) { 'WaitCursor' } else { 'Default' }
    [Windows.Forms.Application]::DoEvents()
}

function Invoke-Check {
    if (-not (Show-Folder)) { $status.Text = 'Pick your AddOns folder first.'; return }
    Set-Busy $true 'Sniffing for updates...'
    $script:state = Read-State
    try {
        for ($i = 0; $i -lt $config.addons.Count; $i++) {
            $addon = $config.addons[$i]
            $grid.Rows[$i].Cells['Status'].Value = 'Checking...'
            $grid.Rows[$i].Cells['Status'].Style.ForeColor = $muted
            [Windows.Forms.Application]::DoEvents()
            $r = Invoke-Background { param($c, $a, $s, $w) Get-AddonStatus $c $a $s $w } @($config, $addon, $state, $work)
            if ($r.firstSeen) { $state[$addon.name] = $r.latest.version; Save-State $state }
            $results[$addon.name] = $r
            Set-RowStatus $grid.Rows[$i]
        }
    } finally { Set-Busy $false ('Checked ' + (Get-Date -Format 't')) }   # never leave the buttons stuck on busy
    Update-Summary
}

function Invoke-Update {
    Set-Busy $true 'Chomping updates...'
    $backup = New-BackupPath
    $done = 0
    try {
        for ($i = 0; $i -lt $config.addons.Count; $i++) {
            $addon = $config.addons[$i]
            $r = $results[$addon.name]
            if ($addon.hold -or -not $r -or $r.status -ne 'update') { continue }
            $grid.Rows[$i].Cells['Status'].Value = 'Installing...'
            [Windows.Forms.Application]::DoEvents()
            try {
                Invoke-Background { param($c, $a, $l, $w, $b) Install-Addon $c $a $l $w $b } @($config, $addon, $r.latest, $work, $backup) | Out-Null
                $state[$addon.name] = $r.latest.version; Save-State $state
                $r.status = 'done'; $done++
            } catch { $r.status = 'failed'; $r.message = $_.Exception.Message }
            Set-RowStatus $grid.Rows[$i]
        }
        Invoke-Background { Remove-OldBackups }
    } finally {
        $msg = "$done addon(s) updated."
        if ($done -and (Test-WowRunning)) { $msg += ' Type /reload in game.' }
        Set-Busy $false $msg
    }
    if ($done) { $status.ForeColor = $kelp }
    Update-Summary
}

function Add-Tracked($entries) {
    foreach ($e in $entries) {
        $config.addons = @($config.addons) + $e
        [void]$grid.Rows.Add($true, $e.name, (Get-InstalledText $e), '', '')
    }
    Save-Config $config
}

function Remove-Tracked($index) {
    $addon = $config.addons[$index]
    $config.addons = @($config.addons | Where-Object { $_.name -ne $addon.name })
    Save-Config $config
    $results.Remove($addon.name)
    if ($state.ContainsKey($addon.name)) { $state.Remove($addon.name); Save-State $state }
    $grid.Rows.RemoveAt($index)
    Update-Summary
    $status.Text = "Stopped tracking $($addon.name) (its files are left alone)."
}

function Show-FindDialog {
    if (-not (Show-Folder)) { $status.Text = 'Pick your AddOns folder first.'; return }
    Set-Busy $true 'Rummaging through your AddOns folder...'
    try { $found = @(Invoke-Background { param($c) Find-NewAddons $c } @(,$config)) } finally { Set-Busy $false '' ; Update-Summary }
    $ok  = @($found | Where-Object { $_.available })
    $bad = @($found | Where-Object { -not $_.available })

    $dlg = New-Object Windows.Forms.Form
    $dlg.Text = 'Find my addons'
    $dlg.Size = New-Object Drawing.Size(560, 500)
    $dlg.StartPosition = 'CenterParent'
    $dlg.BackColor = $sea; $dlg.ForeColor = $foam; $dlg.Font = $font
    $dlg.FormBorderStyle = 'FixedDialog'; $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    if ($form.Icon) { $dlg.Icon = $form.Icon }

    $msg = New-Object Windows.Forms.Label
    $msg.Location = New-Object Drawing.Point(16, 12); $msg.Size = New-Object Drawing.Size(512, 40)
    $msg.Text = if ($ok.Count) { "Found $($ok.Count) addon(s) I can keep updated. Tick the ones to add:" } else { 'No new addons found that I know how to update.' }
    $dlg.Controls.Add($msg)

    $list = New-Object Windows.Forms.CheckedListBox
    $list.Location = New-Object Drawing.Point(16, 56); $list.Size = New-Object Drawing.Size(512, 200)
    $list.BackColor = $panel; $list.ForeColor = $foam; $list.BorderStyle = 'None'; $list.CheckOnClick = $true
    foreach ($c in $ok) { [void]$list.Items.Add($c.name, $true) }
    $dlg.Controls.Add($list)

    $note = New-Object Windows.Forms.Label
    $note.Location = New-Object Drawing.Point(16, 262); $note.Size = New-Object Drawing.Size(512, 60)
    $note.ForeColor = $muted
    $note.Text = if ($bad.Count) { 'No WoW Forever version on CurseForge: ' + ($bad.name -join ', ') } else { "Not listed? It isn't on CurseForge or WoWInterface for Forever - add it by GitHub link below." }
    $dlg.Controls.Add($note)

    $linkLbl = New-Object Windows.Forms.Label
    $linkLbl.Text = 'Add from a GitHub link (github.com/owner/repo):'
    $linkLbl.Location = New-Object Drawing.Point(16, 326); $linkLbl.AutoSize = $true
    $dlg.Controls.Add($linkLbl)
    $link = New-Object Windows.Forms.TextBox
    $link.Location = New-Object Drawing.Point(16, 350); $link.Size = New-Object Drawing.Size(400, 26)
    $link.BackColor = $panel; $link.ForeColor = $foam; $link.BorderStyle = 'FixedSingle'
    $dlg.Controls.Add($link)
    $btnLink = New-Object Windows.Forms.Button
    $btnLink.Text = 'Add link'; $btnLink.Location = New-Object Drawing.Point(424, 348); $btnLink.Size = New-Object Drawing.Size(104, 28)
    $btnLink.FlatStyle = 'Flat'; $btnLink.FlatAppearance.BorderColor = $aqua; $btnLink.ForeColor = $aqua
    $dlg.Controls.Add($btnLink)

    $btnAdd = New-Object Windows.Forms.Button
    $btnAdd.Text = 'Add ticked'; $btnAdd.Location = New-Object Drawing.Point(296, 406); $btnAdd.Size = New-Object Drawing.Size(112, 34)
    $btnAdd.FlatStyle = 'Flat'; $btnAdd.FlatAppearance.BorderColor = $aqua; $btnAdd.FlatAppearance.BorderSize = 2; $btnAdd.ForeColor = $aqua; $btnAdd.Font = $bold
    $dlg.Controls.Add($btnAdd)
    $btnClose = New-Object Windows.Forms.Button
    $btnClose.Text = 'Close'; $btnClose.Location = New-Object Drawing.Point(416, 406); $btnClose.Size = New-Object Drawing.Size(112, 34)
    $btnClose.FlatStyle = 'Flat'; $btnClose.FlatAppearance.BorderColor = C '#1f6f9a'
    $btnClose.DialogResult = 'Cancel'
    $dlg.Controls.Add($btnClose)

    if ($FindShot) {
        $dlg.add_Shown({
            [Windows.Forms.Application]::DoEvents()
            $b = New-Object Drawing.Bitmap($dlg.Width, $dlg.Height)
            $dlg.DrawToBitmap($b, (New-Object Drawing.Rectangle(0, 0, $dlg.Width, $dlg.Height)))
            $b.Save(($Screenshot -replace '\.png$', '-find.png'), [Drawing.Imaging.ImageFormat]::Png)
            $btnAdd.PerformClick()
        })
    }

    $script:added = 0
    $btnLink.add_Click({
        try {
            $e = New-GithubEntry $config $link.Text.Trim()
            if ($config.addons.name -contains $e.name) { throw "$($e.name) is already on your list." }
            Add-Tracked @($e); $script:added++
            $note.ForeColor = $kelp; $note.Text = "Added $($e.name)."; $link.Text = ''
        } catch { $note.ForeColor = $coral; $note.Text = "Couldn't add that link: $($_.Exception.Message)" }
    })
    $btnAdd.add_Click({
        $pick = @($ok | Where-Object { $list.CheckedItems -contains $_.name })
        Add-Tracked @($pick | ForEach-Object { $_.entry }); $script:added += $pick.Count
        $dlg.Close()
    })
    [void]$dlg.ShowDialog($form)
    if ($script:added) { Invoke-Check }
}

# ---------- first run: find the AddOns folder ----------
if (-not $config.addonsPath -or -not (Test-Path $config.addonsPath)) {
    $found = Find-AddonsPath
    if ($found) { Set-AddonsPath $found }
}
Show-Folder | Out-Null

# ---------- fill rows ----------
foreach ($addon in $config.addons) {
    [void]$grid.Rows.Add((-not $addon.hold), $addon.name, (Get-InstalledText $addon), '', '')
}

# ---------- events ----------
$grid.add_CurrentCellDirtyStateChanged({
    if ($grid.IsCurrentCellDirty) { $grid.CommitEdit('CurrentCellChange') }
})
$grid.add_CellValueChanged({
    param($s, $e)
    if ($e.RowIndex -lt 0 -or $grid.Columns[$e.ColumnIndex].Name -ne 'On') { return }
    $addon = $config.addons[$e.RowIndex]
    $on = [bool]$grid.Rows[$e.RowIndex].Cells['On'].Value
    $addon | Add-Member -NotePropertyName hold -NotePropertyValue (-not $on) -Force
    Save-Config $config
    Set-RowStatus $grid.Rows[$e.RowIndex]
    Update-Summary
})
$btnFolder.add_Click({
    if ($script:busy) { return }
    $dlg = New-Object Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Pick your WoW AddOns folder (World of Warcraft\_forever_\Interface\AddOns)'
    if ($config.addonsPath -and (Test-Path $config.addonsPath)) { $dlg.SelectedPath = $config.addonsPath }
    if ($dlg.ShowDialog() -ne 'OK') { return }
    $path = $dlg.SelectedPath
    # Accept the WoW folder or the _forever_ folder too, and walk down to AddOns.
    foreach ($tail in '_forever_\Interface\AddOns', 'Interface\AddOns', 'AddOns') {
        if (Test-Path (Join-Path $path $tail)) { $path = Join-Path $path $tail; break }
    }
    if ((Split-Path $path -Leaf) -ne 'AddOns') {
        [Windows.Forms.MessageBox]::Show("That doesn't look like an AddOns folder:`n$path", 'Change folder', 'OK', 'Warning') | Out-Null
        return
    }
    Set-AddonsPath $path
    $script:state = @{}; Save-State $state   # versions belong to the old folder
    foreach ($row in $grid.Rows) { Set-RowStatus $row }
    Invoke-Check
})
$btnFind.add_Click({ if (-not $script:busy) { Show-FindDialog } })
$newVer.add_LinkClicked({
    if ($script:busy) { return }
    $u = $newVer.Tag
    # A git clone (the developer's copy) updates with git instead: just open the release page.
    if (Test-Path (Join-Path $PSScriptRoot '.git')) { Start-Process $u.url; return }
    $ans = [Windows.Forms.MessageBox]::Show("Update Grumpy Shark Updater to $($u.version)?`nYour addon list and backups stay as they are. The window reopens when it's done.", 'Update the updater', 'YesNo', 'Question')
    if ($ans -ne 'Yes') { return }
    Set-Busy $true "Fetching version $($u.version)..."
    try { Invoke-Background { param($u) Install-AppUpdate $u } @(,$u) }
    catch {
        Set-Busy $false "Couldn't update: $($_.Exception.Message) Opening the download page instead."
        $status.ForeColor = $coral; Start-Process $u.url; return
    }
    Set-Busy $false 'Updated - reopening...'
    Start-Process (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`""
    $form.Close()
})

# Right-click a row -> Stop tracking.
$menu = New-Object Windows.Forms.ContextMenuStrip
$stopItem = $menu.Items.Add('Stop tracking this addon')
$grid.ContextMenuStrip = $menu
$grid.add_CellMouseDown({
    param($s, $e)
    if ($e.Button -eq 'Right' -and $e.RowIndex -ge 0) { $grid.ClearSelection(); $grid.Rows[$e.RowIndex].Selected = $true; $grid.CurrentCell = $grid.Rows[$e.RowIndex].Cells[1] }
})
$menu.add_Opening({ param($s, $e) if ($grid.SelectedRows.Count -eq 0) { $e.Cancel = $true } })
$stopItem.add_Click({ if ($grid.SelectedRows.Count) { Remove-Tracked $grid.SelectedRows[0].Index } })

$btnCheck.add_Click({ if (-not $script:busy) { Invoke-Check } })
$btnUpdate.add_Click({ if (-not $script:busy -and $script:pending) { Invoke-Update } })
$btnUndo.add_Click({
    if ($script:busy) { return }
    $ans = [Windows.Forms.MessageBox]::Show('Put back the addon versions from before the last update?', 'Undo last update', 'YesNo', 'Question')
    if ($ans -ne 'Yes') { return }
    Set-Busy $true 'Putting the old versions back...'
    try { $names = @(Invoke-Background { param($c) Restore-LastBackup $c } @(,$config)) } finally { Set-Busy $false '' }
    if (-not $names) { $status.Text = 'Nothing to undo.'; return }
    $status.Text = "Restored: $($names -join ', ')"
    Invoke-Check
})

$form.add_Shown({
    # Launched from a hidden PowerShell, Windows can leave the window behind others; pull it to the front.
    $form.TopMost = $true; $form.Activate(); $form.TopMost = $false
    $grid.ClearSelection()
    Invoke-Check
    $u = Get-AppUpdate
    if ($u) {
        $newVer.Text = "New version $($u.version) available - click to update"
        $newVer.Tag = $u
        $newVer.Location = New-Object Drawing.Point(($header.Width - $newVer.PreferredWidth - 16), 84)
        $newVer.Visible = $true
    }
    if ($FindShot) { Show-FindDialog }
    if ($Screenshot) {
        $grid.ClearSelection()
        [Windows.Forms.Application]::DoEvents()
        $bmp = New-Object Drawing.Bitmap($form.Width, $form.Height)
        $form.DrawToBitmap($bmp, (New-Object Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
        $bmp.Save($Screenshot, [Drawing.Imaging.ImageFormat]::Png)
        $form.Close()
    }
})

# Closing mid-update could leave an addon half-moved: wait until the current job finishes.
$form.add_FormClosing({ param($s, $e) if ($script:busy) { $e.Cancel = $true; $status.Text = 'Hang on, still working - close me when this finishes.' } })

[void]$form.ShowDialog()
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
