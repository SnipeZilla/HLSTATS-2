$host.UI.RawUI.WindowTitle = "HLSTATS - $(Get-Date -Format 'HH:mm:ss')"
Set-Location -Path $PSScriptRoot
$perlPath = "C:\Strawberry\perl\bin\perl.exe"
$scriptPath = Join-Path $PSScriptRoot "hlstats.pl"
while ($true) {
    Start-Process -FilePath $perlPath -ArgumentList $scriptPath -Wait
    Start-Sleep -Seconds 1
}
