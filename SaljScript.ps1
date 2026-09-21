# Saljscript / saljcoach for Diktatorn - OPTIONAL COMPONENT, own file.
#
# Diktatorn dot-sources this if it sits next to Diktatorn.ps1, exactly like
# Telefonassistent.ps1. Leave the file out (the installer's "Saljcoach" component
# unchecked) and the rest of the app runs unchanged: the tray entry disappears,
# the dashboard line stays empty, and the auto-check in the meeting loop is
# skipped because $script:scriptForm is never created.
#
# It lives here rather than in a separate app on purpose. The auto-check feature
# reads $script:meetLines live while a meeting transcribes - across a process
# boundary that would need IPC, which would make the best feature the fragile one.
#
# Needs from the host: $root/SvText/UiFont/Write-Log, $tray for balloon tips,
# and Get-CoachKey + Invoke-CoachLLM for the AI parts.

# Where the user's call scripts live. Created here, not in Diktatorn.ps1, so an
# install without this component never makes the folder.
$scriptsDir = Join-Path ([System.Environment]::GetFolderPath('MyDocuments')) 'SalesScripts'
New-Item -ItemType Directory -Force $scriptsDir | Out-Null
if (-not (Get-ChildItem $scriptsDir -Filter '*.md' -ErrorAction SilentlyContinue)) {
    $exampleScript = Join-Path $PSScriptRoot 'exempel-saljsamtal.md'
    if (Test-Path $exampleScript) { Copy-Item $exampleScript $scriptsDir -ErrorAction SilentlyContinue }
}

# --- Sales script screen: always-on-top checklist guiding a prepared call. Items are
# checked manually, or AUTOMATICALLY during a live meeting: new transcript chunks are
# matched against unchecked items by the coach engine ("Budget? -> covered").
$script:scriptForm = $null
$script:scriptChecks = @()
$script:scriptLastLine = 0

function Parse-SalesScript([string]$path) {
    $items = @()
    foreach ($line in (Get-Content $path -Encoding UTF8)) {
        $t = $line.Trim()
        if (-not $t) { continue }
        if ($t -match '^#{1,3}\s*(.+)$') { $items += @{ kind = 'section'; text = $Matches[1].Trim() } }
        elseif ($t -match '^[-*]\s*(?:\[[ xX]\]\s*)?(.+)$') { $items += @{ kind = 'item'; text = $Matches[1].Trim() } }
    }
    return ,$items
}

function Open-ScriptWindow([string]$path) {
    if ($script:scriptForm -and -not $script:scriptForm.IsDisposed) { $script:scriptForm.Close() }
    $items = Parse-SalesScript $path
    if (@($items).Count -eq 0) {
        $tray.ShowBalloonTip(3000, 'Diktatorn', (SvText 'Scriptet ~er tomt. Anv~end ## rubriker och - punkter.'), 'Warning')
        return
    }
    $f = New-Object System.Windows.Forms.Form
    $f.Text = (SvText 'S~eljscript - ') + [System.IO.Path]::GetFileNameWithoutExtension($path)
    $f.TopMost = $true
    $f.Size = New-Object System.Drawing.Size(390, 580)
    $f.StartPosition = 'Manual'
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $f.Location = New-Object System.Drawing.Point(($wa.Right - 410), 60)
    $f.FormBorderStyle = 'SizableToolWindow'
    $status = New-Object System.Windows.Forms.Label
    $status.Dock = 'Bottom'; $status.Height = 22
    $status.Text = 'Manuell avbockning - auto nar mote kor live.'
    $panel = New-Object System.Windows.Forms.FlowLayoutPanel
    $panel.Dock = 'Fill'; $panel.FlowDirection = 'TopDown'; $panel.WrapContents = $false
    $panel.AutoScroll = $true; $panel.Padding = '8,8,8,8'
    $script:scriptChecks = @()
    foreach ($it in $items) {
        if ($it.kind -eq 'section') {
            $l = New-Object System.Windows.Forms.Label
            $l.Text = $it.text; $l.AutoSize = $true
            $l.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
            $l.Margin = '0,10,0,2'
            [void]$panel.Controls.Add($l)
        } else {
            $cb = New-Object System.Windows.Forms.CheckBox
            $cb.Text = $it.text; $cb.AutoSize = $true
            $cb.MaximumSize = New-Object System.Drawing.Size(340, 0)
            $cb.Margin = '12,2,0,2'
            [void]$panel.Controls.Add($cb)
            $script:scriptChecks += $cb
        }
    }
    $f.Controls.Add($panel); $f.Controls.Add($status)
    $script:scriptForm = $f
    $script:scriptStatus = $status
    $script:scriptLastLine = 0
    $f.Show()
}

# --- Script manager: list / edit / create / AI-generate the call scripts ---
$script:mgrForm = $null

function Get-ScriptFiles { return @(Get-ChildItem $scriptsDir -Filter '*.md' -ErrorAction SilentlyContinue | Sort-Object Name) }

function New-ScriptName([string]$title) {
    # Keep filenames ASCII-safe: the folder is user-facing and gets synced/mailed around.
    $sw_a = [char]229; $sw_ao = [char]228; $sw_o = [char]246
    $n = $title -replace [string]$sw_a, 'a' -replace [string]$sw_ao, 'a' -replace [string]$sw_o, 'o'
    $n = $n -replace [char]197, 'A' -replace [char]196, 'A' -replace [char]214, 'O'
    $n = ($n -replace '[^\w\s-]', '' -replace '\s+', '-').Trim('-')
    if (-not $n) { $n = 'script' }
    return "$n.md"
}

# Ask the coach engine for a script. Returns markdown, or throws.
function Get-AIScript([string]$brief, [string]$existing) {
    $sys = 'You write sales-call scripts as MARKDOWN CHECKLISTS in SWEDISH. Output ONLY the markdown, no preamble, no code fences. Use "## Rubrik" for each phase of the call and "- punkt" for each item under it. Every item must be something the seller DOES or ASKS, phrased so it can be ticked off during the call - short, concrete, one action each. Cover the natural arc: opening, needs discovery, decision process, pitch, objections, close with a concrete next step. 5-7 sections, 3-5 items each. No filler, no explanations, no numbering.'
    if ($existing) {
        $usr = "Forbattra det har saljscriptet. Behall det som fungerar, gor punkterna vassare och mer konkreta, fyll luckor i samtalsbagen.`n`nBESKRIVNING AV MOTET:`n$brief`n`nNUVARANDE SCRIPT:`n$existing"
    } else {
        $usr = "Skriv ett saljscript for det har motet:`n$brief"
    }
    $md = Invoke-CoachLLM $sys $usr
    # Models sometimes wrap the answer in a fence despite being told not to
    $md = $md -replace '(?m)^```[a-z]*\s*$', ''
    return $md.Trim()
}

# Every control and helper the button handlers touch lives in $script: scope on
# purpose. Event handlers run long after Open-ScriptManager has returned, and a
# handler that closes over the function's LOCALS finds them gone by then - the
# buttons silently do nothing (verified: clicks produced no effect at all).
$script:mgrList = $null
$script:mgrEditor = $null
$script:mgrStatus = $null
$script:mgrCurrent = $null
$script:mgrDirty = $false

function Update-ScriptList([string]$selectName) {
    $script:mgrList.Items.Clear()
    foreach ($fi in Get-ScriptFiles) { [void]$script:mgrList.Items.Add($fi.Name) }
    if ($selectName) {
        $ix = $script:mgrList.Items.IndexOf($selectName)
        if ($ix -ge 0) { $script:mgrList.SelectedIndex = $ix; return }
    }
    if ($script:mgrList.Items.Count -gt 0) { $script:mgrList.SelectedIndex = 0 }
}
function Save-CurrentScript {
    if (-not $script:mgrCurrent) { return $true }
    try {
        [System.IO.File]::WriteAllText($script:mgrCurrent, $script:mgrEditor.Text, [System.Text.UTF8Encoding]::new($true))
        $script:mgrDirty = $false
        $script:mgrStatus.Text = " Sparat: $([System.IO.Path]::GetFileName($script:mgrCurrent))"
        return $true
    } catch {
        [void][System.Windows.Forms.MessageBox]::Show("Kunde inte spara: $($_.Exception.Message)", 'Diktatorn')
        return $false
    }
}
function Confirm-ScriptSave {
    if (-not $script:mgrDirty -or -not $script:mgrCurrent) { return $true }
    $r = [System.Windows.Forms.MessageBox]::Show('Spara andringarna?', 'Diktatorn', 'YesNoCancel', 'Question')
    if ($r -eq 'Cancel') { return $false }
    if ($r -eq 'Yes') { return (Save-CurrentScript) }
    $script:mgrDirty = $false
    return $true
}
function Invoke-ScriptAI([bool]$improve) {
    if (-not (Get-CoachKey $script:coach)) {
        [void][System.Windows.Forms.MessageBox]::Show("Coach-motorn ($($script:coach)) saknar API-nyckel. Valj motor eller ange nyckel i tray-menyn.", 'Diktatorn')
        return
    }
    if ($improve -and -not $script:mgrCurrent) { return }
    Add-Type -AssemblyName Microsoft.VisualBasic
    $prompt = if ($improve) { 'Vad ska forbattras? (t.ex. "fler fragor om budget", "kortare oppning")' }
              else { 'Beskriv motet: vem du traffar, vad du saljer, vilket steg i processen.' }
    $brief = [Microsoft.VisualBasic.Interaction]::InputBox($prompt, 'AI-script', '')
    if (-not $brief) { return }
    $script:mgrForm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $script:mgrStatus.Text = " Fragar $($script:coach)..."
    [System.Windows.Forms.Application]::DoEvents()
    try {
        $md = Get-AIScript $brief $(if ($improve) { $script:mgrEditor.Text } else { $null })
        if (-not $md) { throw 'Tomt svar fran modellen' }
        if ($improve) {
            $script:mgrEditor.Text = $md
            $script:mgrDirty = $true
            $script:mgrStatus.Text = ' Forbattrat - granska och spara'
        } else {
            $title = ($brief -split '[.,\n]')[0]
            if ($title.Length -gt 40) { $title = $title.Substring(0, 40) }
            $path = Join-Path $scriptsDir (New-ScriptName $title)
            $i = 2
            while (Test-Path $path) { $path = Join-Path $scriptsDir ((New-ScriptName $title) -replace '\.md$', "-$i.md"); $i++ }
            [System.IO.File]::WriteAllText($path, $md, [System.Text.UTF8Encoding]::new($true))
            Update-ScriptList ([System.IO.Path]::GetFileName($path))
            $script:mgrStatus.Text = ' Genererat - granska innan du anvander det'
        }
    } catch {
        Write-Log "AI-script: $($_.Exception.Message)"
        [void][System.Windows.Forms.MessageBox]::Show("Kunde inte generera: $($_.Exception.Message)", 'Diktatorn')
        $script:mgrStatus.Text = ' Misslyckades'
    } finally { $script:mgrForm.Cursor = [System.Windows.Forms.Cursors]::Default }
}

function Open-ScriptManager {
    if ($script:mgrForm -and -not $script:mgrForm.IsDisposed) { $script:mgrForm.Activate(); return }
    $f = New-Object System.Windows.Forms.Form
    $f.Text = (SvText 'S~eljscript')
    $f.Size = New-Object System.Drawing.Size(880, 600)
    $f.StartPosition = 'CenterScreen'
    $f.MinimumSize = New-Object System.Drawing.Size(700, 440)
    $script:mgrForm = $f

    $bar = New-Object System.Windows.Forms.FlowLayoutPanel
    $bar.Dock = 'Bottom'; $bar.Height = 42; $bar.Padding = '6,6,6,6'
    $script:mgrStatus = New-Object System.Windows.Forms.Label
    $script:mgrStatus.Dock = 'Bottom'; $script:mgrStatus.Height = 20; $script:mgrStatus.Text = ' '

    $split = New-Object System.Windows.Forms.SplitContainer
    $split.Dock = 'Fill'
    $script:mgrList = New-Object System.Windows.Forms.ListBox
    $script:mgrList.Dock = 'Fill'
    $script:mgrList.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $split.Panel1.Controls.Add($script:mgrList)
    $script:mgrEditor = New-Object System.Windows.Forms.TextBox
    $script:mgrEditor.Multiline = $true; $script:mgrEditor.Dock = 'Fill'
    $script:mgrEditor.ScrollBars = 'Both'; $script:mgrEditor.AcceptsTab = $true
    $script:mgrEditor.WordWrap = $false
    $script:mgrEditor.Font = New-Object System.Drawing.Font('Consolas', 10)
    $split.Panel2.Controls.Add($script:mgrEditor)

    $f.Controls.Add($split); $f.Controls.Add($bar); $f.Controls.Add($script:mgrStatus)
    $split.SplitterDistance = 230

    $mk = {
        param($text, $width, $handler)
        $b = New-Object System.Windows.Forms.Button
        $b.Text = $text; $b.Width = $width; $b.Height = 28
        $b.add_Click($handler)
        [void]$bar.Controls.Add($b)
    }
    & $mk 'Spara'           80 { [void](Save-CurrentScript) }
    & $mk 'Nytt'            70 {
        if (-not (Confirm-ScriptSave)) { return }
        Add-Type -AssemblyName Microsoft.VisualBasic
        $t = [Microsoft.VisualBasic.Interaction]::InputBox('Namn pa scriptet:', 'Nytt saljscript', 'Nytt samtal')
        if (-not $t) { return }
        $path = Join-Path $scriptsDir (New-ScriptName $t)
        if (Test-Path $path) { [void][System.Windows.Forms.MessageBox]::Show('Det finns redan ett script med det namnet.', 'Diktatorn'); return }
        [System.IO.File]::WriteAllText($path, "# $t`r`n`r`n## Oppning`r`n- `r`n`r`n## Behovsanalys`r`n- `r`n`r`n## Avslut`r`n- `r`n", [System.Text.UTF8Encoding]::new($true))
        Update-ScriptList ([System.IO.Path]::GetFileName($path))
    }
    & $mk 'Generera med AI' 130 { Invoke-ScriptAI $false }
    & $mk 'Forbattra'       95 { Invoke-ScriptAI $true }
    & $mk 'Kopiera'         85 {
        if (-not $script:mgrCurrent) { return }
        $base = [System.IO.Path]::GetFileNameWithoutExtension($script:mgrCurrent)
        $path = Join-Path $scriptsDir "$base-kopia.md"
        $i = 2
        while (Test-Path $path) { $path = Join-Path $scriptsDir "$base-kopia$i.md"; $i++ }
        Copy-Item $script:mgrCurrent $path
        Update-ScriptList ([System.IO.Path]::GetFileName($path))
    }
    & $mk 'Ta bort'         85 {
        if (-not $script:mgrCurrent) { return }
        $name = [System.IO.Path]::GetFileName($script:mgrCurrent)
        if ([System.Windows.Forms.MessageBox]::Show("Ta bort $name?", 'Diktatorn', 'YesNo', 'Warning') -ne 'Yes') { return }
        try { Remove-Item $script:mgrCurrent -Force } catch {}
        $script:mgrCurrent = $null; $script:mgrDirty = $false; $script:mgrEditor.Text = ''
        Update-ScriptList $null
    }
    & $mk 'Anvand i samtal' 130 {
        if (-not $script:mgrCurrent) { return }
        if (-not (Confirm-ScriptSave)) { return }
        Open-ScriptWindow $script:mgrCurrent
    }
    & $mk 'Oppna mappen'   110 { Invoke-Item $scriptsDir }

    $script:mgrEditor.add_TextChanged({ if ($script:mgrCurrent) { $script:mgrDirty = $true } })
    $script:mgrList.add_SelectedIndexChanged({
        if (-not $script:mgrList.SelectedItem) { return }
        $path = Join-Path $scriptsDir $script:mgrList.SelectedItem
        if ($path -eq $script:mgrCurrent) { return }
        if (-not (Confirm-ScriptSave)) { return }
        $script:mgrCurrent = $path
        try { $script:mgrEditor.Text = [System.IO.File]::ReadAllText($path) } catch { $script:mgrEditor.Text = '' }
        $script:mgrDirty = $false
        $script:mgrStatus.Text = " $($script:mgrList.SelectedItem)"
    })
    $f.add_FormClosing({ if (-not (Confirm-ScriptSave)) { $_.Cancel = $true } })

    Update-ScriptList $null
    $f.Show()
}

function Open-ScriptPicker { Open-ScriptManager }
