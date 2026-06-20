<#
  Register Imprint with Windows Task Scheduler (current user, no admin needed).

  Two mutually-exclusive strategies (don't use both - prompts would double-fire):

  Default (recommended): one task that runs `start.ps1 -Cron` AT LOGON. That
  starts the services + the cron daemon (scripts/cron_daemon.py), which fires
  the cron-schedule.json tasks while you're logged in.

  -PerTask: instead register one task per cron-schedule.json entry on its own
  daily/weekly trigger (survives reboot, no daemon needed, but no tunnel/dashboard).

  Usage:
    powershell -ExecutionPolicy Bypass -File setup-scheduler.ps1             # logon startup task
    powershell -ExecutionPolicy Bypass -File setup-scheduler.ps1 -PerTask    # per-prompt tasks
    powershell -ExecutionPolicy Bypass -File setup-scheduler.ps1 -Unregister # remove everything
    powershell -ExecutionPolicy Bypass -File setup-scheduler.ps1 -DryRun     # show, don't apply
#>

param(
    [switch]$PerTask,
    [switch]$Unregister,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

$ProjectDir   = $PSScriptRoot
$StartPs1     = Join-Path $ProjectDir "start.ps1"
$CronPs1      = Join-Path $ProjectDir "cron-task.ps1"
$ScheduleFile = Join-Path $ProjectDir "cron-schedule.json"
$Prefix       = "ImprintCron_"          # per-prompt task name prefix
$StartupName  = "Imprint_Startup"       # logon startup task name
$User         = "$env:USERDOMAIN\$env:USERNAME"

$Settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

function Remove-ImprintTask($name) {
    try {
        Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction Stop
        Write-Host "  removed $name"
    } catch {
        Write-Host "  - $name not present"
    }
}

# ---- Unregister everything (both strategies) ----
if ($Unregister) {
    if ($DryRun) { Write-Host "[dry-run] would remove $StartupName and $Prefix*"; return }
    Remove-ImprintTask $StartupName
    if (Test-Path $ScheduleFile) {
        foreach ($e in (Get-Content $ScheduleFile -Raw | ConvertFrom-Json)) {
            Remove-ImprintTask "$Prefix$($e.name)"
        }
    }
    Write-Host "Done."
    return
}

# ---- Per-prompt tasks (alternative strategy) ----
if ($PerTask) {
    if (-not (Test-Path $ScheduleFile)) { throw "Schedule file not found: $ScheduleFile" }
    foreach ($e in (Get-Content $ScheduleFile -Raw | ConvertFrom-Json)) {
        $taskName  = "$Prefix$($e.name)"
        $promptAbs = Join-Path $ProjectDir $e.prompt
        $day  = ([string]$e.day).ToLower()
        $time = [string]$e.time
        $arg  = "-NoProfile -ExecutionPolicy Bypass -File `"$CronPs1`" $($e.name) `"$promptAbs`""
        $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $arg -WorkingDirectory $ProjectDir
        if ($day -eq "daily") {
            $trigger = New-ScheduledTaskTrigger -Daily -At $time
        } else {
            $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek ((Get-Culture).TextInfo.ToTitleCase($day)) -At $time
        }
        if ($DryRun) { Write-Host "[dry-run] $taskName -> $day at $time"; continue }
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
            -Settings $Settings -Description "Imprint cron task: $($e.name)" -Force | Out-Null
        Write-Host "registered $taskName ($day at $time)"
    }
    if (-not $DryRun) { Write-Host "`nDone (per-prompt). Remove with: setup-scheduler.ps1 -Unregister" }
    return
}

# ---- Default: logon startup task running start.ps1 -Cron ----
$arg = "-NoProfile -ExecutionPolicy Bypass -File `"$StartPs1`" -Cron"
$action  = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $arg -WorkingDirectory $ProjectDir
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $User

if ($DryRun) {
    Write-Host "[dry-run] $StartupName -> at logon (user $User)"
    Write-Host "          powershell.exe $arg"
    return
}

Register-ScheduledTask -TaskName $StartupName -Action $action -Trigger $trigger `
    -Settings $Settings -Description "Imprint: start services + cron daemon at logon" -Force | Out-Null
Write-Host "registered $StartupName (at logon -> start.ps1 -Cron)"
Write-Host ""
Write-Host "Run it now to test:  Start-ScheduledTask -TaskName '$StartupName'"
Write-Host "Remove with:         setup-scheduler.ps1 -Unregister"
