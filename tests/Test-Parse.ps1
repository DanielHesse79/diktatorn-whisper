# Every shipped .ps1 must parse cleanly - the cheapest whole-file regression net
# there is for a runtime-compiled app with no build step.
. (Join-Path $PSScriptRoot '_TestLib.ps1')

foreach ($f in @('Diktatorn.ps1', 'Telefonassistent.ps1', 'Install-Diktatorn.ps1', 'Generate-Icon.ps1')) {
    $path = Join-Path $script:RepoRoot $f
    if (-not (Test-Path $path)) { Check $f $false 'saknas'; continue }
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors) | Out-Null
    Check $f ($errors.Count -eq 0) $(if ($errors) { "rad $($errors[0].Extent.StartLineNumber): $($errors[0].Message)" })
}
Complete-Test
