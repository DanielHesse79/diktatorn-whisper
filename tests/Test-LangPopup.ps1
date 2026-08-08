# The Ctrl+Shift+M language popup must return 'sv'/'en' for the clicked button
# and $null when dismissed. Regression: the first version used .GetNewClosure()
# and every click handler silently no-op'd (closures over function locals go
# null on the dialog's nested message loop).
. (Join-Path $PSScriptRoot '_TestLib.ps1')
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Import-AppFunction 'Diktatorn.ps1' @('Show-MeetLangPrompt')
$script:meetLang = 'sv'

function Invoke-Popup([string]$buttonText) {
    # ShowDialog blocks, so a WinForms timer clicks (or closes) from inside the loop.
    $t = New-Object System.Windows.Forms.Timer
    $t.Interval = 250
    $t.add_Tick({
        $t.Stop()
        $f = [System.Windows.Forms.Application]::OpenForms | Where-Object { $_.Text -eq 'Motessprak' } | Select-Object -First 1
        if (-not $f) { return }
        if ($buttonText) {
            $b = $f.Controls | Where-Object { $_ -is [System.Windows.Forms.Button] -and $_.Text -eq $buttonText } | Select-Object -First 1
            if ($b) { $b.PerformClick(); return }
        }
        $f.Close()
    }.GetNewClosure())
    $t.Start()
    $result = Show-MeetLangPrompt
    $t.Dispose()
    return $result
}

Check "klick Svenska -> 'sv'"  ((Invoke-Popup 'Svenska')  -eq 'sv')
Check "klick Engelska -> 'en'" ((Invoke-Popup 'Engelska') -eq 'en')
Check 'stang (X) -> null'      ($null -eq (Invoke-Popup $null))
Complete-Test
