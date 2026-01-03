$host.UI.RawUI.WindowTitle = "HLstatsZ"

Set-Location -Path $PSScriptRoot
$perlPath = "C:\Strawberry\perl\bin\perl.exe"
$scriptPath = Join-Path $PSScriptRoot "hlstats.pl"

while ($true) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $perlPath
    $psi.Arguments = "`"$scriptPath`""
    $psi.UseShellExecute = $false
    $psi.WorkingDirectory = $PSScriptRoot
    $process = [System.Diagnostics.Process]::Start($psi)
    $process.PriorityClass = 'AboveNormal'
    $process.WaitForExit()
    Start-Sleep -Seconds 1
}