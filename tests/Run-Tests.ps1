# Runs every Test-*.ps1 in this folder, each in its own Windows PowerShell 5.1
# STA process (the app's runtime; isolation means a crashing test can't take the
# runner down). Exit-code convention: 0 = pass, 2 = skip, anything else = fail.
#
#   powershell -ExecutionPolicy Bypass -File tests\Run-Tests.ps1
#   powershell -ExecutionPolicy Bypass -File tests\Run-Tests.ps1 -Network   # + Groq-testerna
param(
    [switch]$Network,
    [int]$TimeoutSec = 120
)
$ErrorActionPreference = 'Stop'
if ($Network) { $env:DIKTATORN_TEST_NETWORK = '1' }

$tests = @(Get-ChildItem $PSScriptRoot -Filter 'Test-*.ps1' | Sort-Object Name)
$results = @()
$sw = [System.Diagnostics.Stopwatch]::StartNew()

foreach ($t in $tests) {
    $outFile = Join-Path $env:TEMP ("dikt_testout_" + $t.BaseName + ".txt")
    Remove-Item $outFile -ErrorAction SilentlyContinue
    $t0 = [System.Diagnostics.Stopwatch]::StartNew()
    $p = Start-Process powershell.exe -PassThru -WindowStyle Hidden `
        -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', "`"$($t.FullName)`"" `
        -RedirectStandardOutput $outFile -RedirectStandardError ($outFile + '.err')
    $null = $p.Handle   # PS 5.1 quirk: without touching Handle first, ExitCode reads as null
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        try { $p.Kill() } catch { }
        $status = 'FAIL'; $note = "timeout efter ${TimeoutSec}s"
    } else {
        $status = switch ($p.ExitCode) { 0 { 'PASS' } 2 { 'SKIP' } default { 'FAIL' } }
        $note = ''
        $out = @(Get-Content $outFile -ErrorAction SilentlyContinue)
        if ($status -eq 'SKIP') { $note = (@($out | Where-Object { $_ -like 'SKIP:*' })[0] -replace '^SKIP:\s*', '') }
        if ($status -eq 'FAIL') { $note = (@($out | Where-Object { $_ -like 'FAIL*' })[0]) }
    }
    $t0.Stop()
    $results += [pscustomobject]@{ Test = $t.BaseName; Status = $status; Sek = [math]::Round($t0.Elapsed.TotalSeconds, 1); Info = $note }
    $mark = switch ($status) { 'PASS' { '+' } 'SKIP' { 'o' } default { 'X' } }
    Write-Host ("[{0}] {1,-26} {2,5}s  {3}" -f $mark, $t.BaseName, [math]::Round($t0.Elapsed.TotalSeconds, 1), $note)
    if ($status -eq 'FAIL') {
        Get-Content $outFile -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "      $_" }
        Get-Content ($outFile + '.err') -ErrorAction SilentlyContinue | Select-Object -First 8 | ForEach-Object { Write-Host "      ERR $_" }
    }
}
$sw.Stop()

$pass = @($results | Where-Object { $_.Status -eq 'PASS' }).Count
$skip = @($results | Where-Object { $_.Status -eq 'SKIP' }).Count
$fail = @($results | Where-Object { $_.Status -eq 'FAIL' }).Count
Write-Host ''
Write-Host ("{0} PASS, {1} SKIP, {2} FAIL  ({3:N0}s totalt)" -f $pass, $skip, $fail, $sw.Elapsed.TotalSeconds)
exit $(if ($fail -gt 0) { 1 } else { 0 })
