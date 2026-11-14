$host.UI.RawUI.WindowTitle = "HLstatsZ Debug"

Set-Location -Path $PSScriptRoot
$scriptPath = Join-Path $PSScriptRoot "hlstats.pl"

while ($true) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'perl'
    $psi.Arguments = "`"$scriptPath`""
    $psi.UseShellExecute = $false
    $psi.WorkingDirectory = $PSScriptRoot
    $process = [System.Diagnostics.Process]::Start($psi)
    $process.PriorityClass = 'AboveNormal'
    $process.WaitForExit()
    Start-Sleep -Seconds 1
}