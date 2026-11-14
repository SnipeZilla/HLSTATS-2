<#
HLstatsZ on Windows: runs hlstats.pl, and starts it again when it stops.
#>
param([string]$Action)

$TaskName = 'HLstatsZ'

# What the scheduled task runs
if ($Action -eq 'run') {
    Set-Location -Path $PSScriptRoot
    while ($true) {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'perl'
        $psi.Arguments = '"{0}" -n' -f (Join-Path $PSScriptRoot 'hlstats.pl')
        $psi.UseShellExecute = $false
        $psi.WorkingDirectory = $PSScriptRoot
        $process = [System.Diagnostics.Process]::Start($psi)
        $process.PriorityClass = 'AboveNormal'
        $process.WaitForExit()
        Start-Sleep -Seconds 1
    }
}

# Not administrator: ask Windows for the rights (a new window opens)
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process -FilePath powershell.exe -Verb RunAs -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $PSCommandPath)
    exit
}

# Ends what runs this folder's HLstatsZ now: the task, hlstats.pl, and the loops that start it again (old
# .bat / .ps1, or this task's), but not this window. Not hlstats-awards.pl, and nothing from another folder.
function Stop-Daemon {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    $files = 'hlstats.pl', 'hlstatsz.ps1', 'task-hlstatsz.bat', 'task-hlstatsz.ps1', 'run-hlstats.ps1' |
        ForEach-Object { (Join-Path $PSScriptRoot $_).ToLower() }
    # Twice: an old loop can start hlstats.pl again in between
    foreach ($pass in 1, 2) {
        foreach ($process in @(Get-CimInstance Win32_Process)) {
            $line = ([string]$process.CommandLine).ToLower()
            if ($process.ProcessId -ne $PID -and @($files | Where-Object { $line.Contains($_) }).Count) {
                Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
            }
        }
        if ($pass -eq 1) { Start-Sleep -Seconds 2 }
    }
}

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($task) {
    # Installed: restart (start when it isn't running), stop, or uninstall
    $start = 'Restart'
    if ($task.State -ne 'Running') { $start = 'Start' }
    Write-Host ('HLstatsZ: the task "{0}" is {1}.' -f $TaskName, $task.State)
    switch ((Read-Host ('1 = {0}, 2 = Stop, 3 = Uninstall, Enter = nothing' -f $start)).Trim()) {
        '1' {
            Stop-Daemon
            if ($task.State -eq 'Disabled') { $task | Enable-ScheduledTask | Out-Null }
            Start-ScheduledTask -TaskName $TaskName
            Write-Host 'HLstatsZ started.' -ForegroundColor Green
        }
        '2' {
            Stop-Daemon
            Write-Host 'HLstatsZ stopped. The task starts it again at boot.' -ForegroundColor Green
        }
        '3' {
            Stop-Daemon
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
            Write-Host ('HLstatsZ stopped, and the task "{0}" removed.' -f $TaskName) -ForegroundColor Green
        }
    }
} elseif ((Read-Host ('Create the task "{0}" (runs HLstatsZ at boot, as SYSTEM)? A HLstatsZ running from this folder is ended. [y/n]' -f $TaskName)) -match '^\s*y') {
    Stop-Daemon

    # ($taskAction, not $action: PowerShell names ignore case, and $Action is the parameter above, a string)
    $taskAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -File "{0}" run' -f $PSCommandPath) -WorkingDirectory $PSScriptRoot
    $atBoot     = New-ScheduledTaskTrigger -AtStartup
    $asSystem   = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    # No time limit (by default a task is stopped after 3 days), one copy only, and it runs on a UPS battery too
    $settings   = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $TaskName -Action $taskAction -Trigger $atBoot -Principal $asSystem -Settings $settings -Force | Out-Null
    Start-ScheduledTask -TaskName $TaskName
    Write-Host ('Task "{0}" installed and started.' -f $TaskName) -ForegroundColor Green
}
Read-Host 'Press Enter to close' | Out-Null
