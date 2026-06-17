<#
  Claude Imprint - Stop services (Windows / PowerShell)

  Reads <DataDir>\processes.json and stops ONLY the PIDs recorded there whose
  process name still matches what was stored. This is deliberate: the box runs
  other cloudflared tunnels and python servers (weather-mcp, Ombre Brain) and a
  name-based "kill all cloudflared/python" would take those down too.

  Usage:
    powershell -ExecutionPolicy Bypass -File stop.ps1
#>

$ErrorActionPreference = "Stop"

$ProjectDir = $PSScriptRoot
$DataDir    = if ($env:IMPRINT_DATA_DIR) { $env:IMPRINT_DATA_DIR } else { Join-Path $env:USERPROFILE ".imprint" }
$ProcFile   = Join-Path $DataDir "processes.json"

Write-Host "Stopping Claude Imprint..."

if (-not (Test-Path $ProcFile)) {
    Write-Host "  Nothing tracked ($ProcFile not found). Already stopped?"
    return
}

$obj = $null
try { $obj = Get-Content $ProcFile -Raw | ConvertFrom-Json } catch {
    Write-Host "  ! Could not parse $ProcFile; removing it." -ForegroundColor Yellow
    Remove-Item $ProcFile -Force -ErrorAction SilentlyContinue
    return
}

foreach ($svc in $obj.PSObject.Properties) {
    $name  = $svc.Name
    $entry = $svc.Value
    if (-not $entry.pid) { continue }
    $procId = [int]$entry.pid

    # Validate against the live process before killing. The recorded PID is the
    # parent of a process tree (pip console-script and venv python launchers
    # spawn the real worker as a child), so we must (a) confirm identity, then
    # (b) kill the whole tree - Stop-Process -Id would leave the worker + port.
    $wp = Get-CimInstance Win32_Process -Filter "ProcessId=$procId" -ErrorAction SilentlyContinue
    if (-not $wp) {
        Write-Host "  - $name not running (PID $procId gone)"
        continue
    }
    $liveName = $wp.Name -replace '\.exe$',''
    if ($liveName -ne $entry.proc_name) {
        # PID recycled by an unrelated process - do NOT touch it
        Write-Host "  - $name PID $procId now '$liveName' (expected '$($entry.proc_name)'), skipping" -ForegroundColor Yellow
        continue
    }
    if ($entry.cmdline_match -and -not ($wp.CommandLine -and $wp.CommandLine.Contains([string]$entry.cmdline_match))) {
        # Same name (e.g. another python/cloudflared) but not our command - skip
        Write-Host "  - $name PID $procId does not match '$($entry.cmdline_match)', skipping" -ForegroundColor Yellow
        continue
    }

    # /T kills the whole tree, /F forces; output is informative only
    $null = & taskkill /PID $procId /T /F 2>&1
    if (Get-Process -Id $procId -ErrorAction SilentlyContinue) {
        Write-Host "  ! $name (PID $procId) may not have stopped" -ForegroundColor Red
    } else {
        Write-Host "  [ok] $name stopped (tree of PID $procId)" -ForegroundColor Green
    }
}

Remove-Item $ProcFile -Force -ErrorAction SilentlyContinue
Write-Host "Done."
