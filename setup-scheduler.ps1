<#
  Register Imprint cron tasks with Windows Task Scheduler.

  Reads cron-schedule.json and creates one scheduled task per entry, each
  running cron-task.ps1. Tasks are created for the current user and survive
  reboots - the native alternative to the schedule daemon
  (scripts/cron_daemon.py).

  Usage:
    powershell -ExecutionPolicy Bypass -File setup-scheduler.ps1            # register
    powershell -ExecutionPolicy Bypass -File setup-scheduler.ps1 -Unregister
    powershell -ExecutionPolicy Bypass -File setup-scheduler.ps1 -DryRun    # show, don't apply
#>

param(
    [switch]$Unregister,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

$ProjectDir   = $PSScriptRoot
$ScheduleFile = Join-Path $ProjectDir "cron-schedule.json"
$Ps1          = Join-Path $ProjectDir "cron-task.ps1"
$Prefix       = "ImprintCron_"

if (-not (Test-Path $ScheduleFile)) { throw "Schedule file not found: $ScheduleFile" }
$entries = Get-Content $ScheduleFile -Raw | ConvertFrom-Json

foreach ($e in $entries) {
    $taskName = "$Prefix$($e.name)"

    if ($Unregister) {
        if ($DryRun) { Write-Host "[dry-run] would remove $taskName"; continue }
        try { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop; Write-Host "removed $taskName" }
        catch { Write-Host "  - $taskName not present" }
        continue
    }

    $promptAbs = Join-Path $ProjectDir $e.prompt
    $day  = ([string]$e.day).ToLower()
    $time = [string]$e.time

    $argument = "-NoProfile -ExecutionPolicy Bypass -File `"$Ps1`" $($e.name) `"$promptAbs`""
    $action   = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $argument -WorkingDirectory $ProjectDir

    if ($day -eq "daily") {
        $trigger = New-ScheduledTaskTrigger -Daily -At $time
    } else {
        $dow = (Get-Culture).TextInfo.ToTitleCase($day)   # monday -> Monday
        $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $dow -At $time
    }

    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

    if ($DryRun) {
        Write-Host "[dry-run] $taskName -> $day at $time"
        Write-Host "          powershell.exe $argument"
        continue
    }

    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
        -Settings $settings -Description "Imprint cron task: $($e.name)" -Force | Out-Null
    Write-Host "registered $taskName ($day at $time)"
}

if (-not $Unregister -and -not $DryRun) {
    Write-Host ""
    Write-Host "Done. View/edit in Task Scheduler (taskschd.msc) under the '$Prefix*' names."
    Write-Host "Remove all with: setup-scheduler.ps1 -Unregister"
}
