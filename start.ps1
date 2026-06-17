<#
  Claude Imprint - Start services (Windows / PowerShell)

  Default starts: memory HTTP + cloudflare quick tunnel + dashboard.
  Optional via switches: -Heartbeat, -Telegram. Disable with -NoTunnel / -NoDashboard.

  Process tracking: <DataDir>\processes.json  (pid + proc_name per service).
  Stopping is done by stop.ps1, which only kills tracked PIDs whose process
  name still matches - so it never touches your other cloudflared/python
  servers (weather-mcp, Ombre Brain, etc.).

  Usage:
    powershell -ExecutionPolicy Bypass -File start.ps1
    powershell -ExecutionPolicy Bypass -File start.ps1 -Heartbeat
    powershell -ExecutionPolicy Bypass -File start.ps1 -NoTunnel -NoDashboard
#>

param(
    [switch]$Heartbeat,
    [switch]$Cron,
    [switch]$Telegram,
    [switch]$NoTunnel,
    [switch]$NoDashboard
)

$ErrorActionPreference = "Stop"

# --- Configuration -------------------------------------------------------
$ProjectDir    = $PSScriptRoot
$DataDir       = if ($env:IMPRINT_DATA_DIR) { $env:IMPRINT_DATA_DIR } else { Join-Path $env:USERPROFILE ".imprint" }
$LogDir        = Join-Path $ProjectDir "logs"
$ProcFile      = Join-Path $DataDir "processes.json"

$VenvPython    = Join-Path $ProjectDir ".venv\Scripts\python.exe"
$MemoryExe     = Join-Path $ProjectDir ".venv\Scripts\imprint-memory.exe"
$DashScript    = Join-Path $ProjectDir "packages\imprint_dashboard\dashboard.py"
$AgentScript   = Join-Path $ProjectDir "packages\imprint_heartbeat\agent.py"

# cloudflared is not on PATH on this box; prefer PATH, fall back to ~\cloudflared.exe
$Cloudflared   = $null
$cf = Get-Command cloudflared -ErrorAction SilentlyContinue
if ($cf) { $Cloudflared = $cf.Source } else {
    $cfLocal = Join-Path $env:USERPROFILE "cloudflared.exe"
    if (Test-Path $cfLocal) { $Cloudflared = $cfLocal }
}

# Dedicated ports to avoid clashing with other local servers (Ombre 8000, weather 3000)
$MemoryPort    = if ($env:IMPRINT_HTTP_PORT)      { [int]$env:IMPRINT_HTTP_PORT }      else { 8010 }
$DashboardPort = if ($env:IMPRINT_DASHBOARD_PORT) { [int]$env:IMPRINT_DASHBOARD_PORT } else { 3010 }

# Export so child processes inherit them
$env:IMPRINT_DATA_DIR       = $DataDir
$env:IMPRINT_HTTP_PORT      = "$MemoryPort"
$env:IMPRINT_DASHBOARD_PORT = "$DashboardPort"

New-Item -ItemType Directory -Force -Path $LogDir  | Out-Null
New-Item -ItemType Directory -Force -Path $DataDir | Out-Null

# --- Process registry helpers --------------------------------------------
function Read-Procs {
    if (Test-Path $ProcFile) {
        try {
            $obj = Get-Content $ProcFile -Raw | ConvertFrom-Json
            $h = @{}
            foreach ($p in $obj.PSObject.Properties) {
                $e = @{}
                foreach ($pp in $p.Value.PSObject.Properties) { $e[$pp.Name] = $pp.Value }
                $h[$p.Name] = $e
            }
            return $h
        } catch { return @{} }
    }
    return @{}
}

function Write-Procs($h) {
    ($h | ConvertTo-Json -Depth 5) | Set-Content -Path $ProcFile -Encoding UTF8
}

function Test-Running($entry) {
    if (-not $entry -or -not $entry.pid) { return $false }
    $wp = Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$entry.pid)" -ErrorAction SilentlyContinue
    if (-not $wp) { return $false }
    $nameOk = ($wp.Name -replace '\.exe$','') -eq $entry.proc_name
    $cmdOk  = (-not $entry.cmdline_match) -or ($wp.CommandLine -and $wp.CommandLine.Contains([string]$entry.cmdline_match))
    return ($nameOk -and $cmdOk)
}

function Test-Port($port) {
    $c = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
    return [bool]$c
}

# Start a hidden background process, return its registry entry (or $null on failure).
function Start-Svc {
    param($File, [string[]]$ArgList, $OutLog, $ErrLog, $ProcName, [hashtable]$Extra)
    $p = Start-Process -FilePath $File -ArgumentList $ArgList `
            -RedirectStandardOutput $OutLog -RedirectStandardError $ErrLog `
            -WindowStyle Hidden -PassThru
    Start-Sleep -Milliseconds 800
    if ($p.HasExited) {
        Write-Host "      ! exited immediately (rc=$($p.ExitCode)); see $ErrLog" -ForegroundColor Red
        return $null
    }
    $entry = @{ pid = $p.Id; proc_name = $ProcName; started_at = (Get-Date -Format "s") }
    if ($Extra) { foreach ($k in $Extra.Keys) { $entry[$k] = $Extra[$k] } }
    return $entry
}

# --- Start ---------------------------------------------------------------
Write-Host "Starting Claude Imprint... ($(Get-Date -Format 'yyyy-MM-dd HH:mm'))"
Write-Host "  Project : $ProjectDir"
Write-Host "  Data    : $DataDir"
Write-Host "========================================"

$procs = Read-Procs

# 1. Memory HTTP service
if ((Test-Running $procs["memory_http"]) -or (Test-Port $MemoryPort)) {
    Write-Host "  [skip] Memory HTTP already running (port $MemoryPort)"
} else {
    Write-Host "  Starting Memory HTTP (port $MemoryPort)..."
    $e = Start-Svc -File $MemoryExe -ArgList @('--http') `
            -OutLog (Join-Path $LogDir "memory.out.log") -ErrLog (Join-Path $LogDir "memory.err.log") `
            -ProcName "imprint-memory" -Extra @{ port = $MemoryPort; cmdline_match = "--http" }
    if ($e) { $procs["memory_http"] = $e; Write-Host "      [ok] PID $($e.pid)" -ForegroundColor Green }
}

# 2. Cloudflare quick tunnel -> memory HTTP
if (-not $NoTunnel) {
    if (Test-Running $procs["tunnel"]) {
        Write-Host "  [skip] Tunnel already running"
    } elseif (-not $Cloudflared) {
        Write-Host "  [skip] cloudflared not found (PATH or ~\cloudflared.exe)"
    } else {
        Write-Host "  Starting Cloudflare quick tunnel -> http://localhost:$MemoryPort ..."
        $tErr = Join-Path $LogDir "tunnel.err.log"
        $e = Start-Svc -File $Cloudflared -ArgList @('tunnel','--url',"http://localhost:$MemoryPort") `
                -OutLog (Join-Path $LogDir "tunnel.out.log") -ErrLog $tErr -ProcName "cloudflared" `
                -Extra @{ cmdline_match = "localhost:$MemoryPort" }
        if ($e) {
            # cloudflared prints the public URL to stderr; poll for it
            $url = $null
            for ($i = 0; $i -lt 15; $i++) {
                if (Test-Path $tErr) {
                    $m = Select-String -Path $tErr -Pattern 'https://[-a-z0-9]+\.trycloudflare\.com' -ErrorAction SilentlyContinue | Select-Object -First 1
                    if ($m) { $url = $m.Matches[0].Value; break }
                }
                Start-Sleep -Milliseconds 600
            }
            if ($url) { $e["url"] = $url }
            $procs["tunnel"] = $e
            Write-Host "      [ok] PID $($e.pid)" -ForegroundColor Green
            if ($url) { Write-Host "      URL: $url/mcp  (paste into claude.ai connector)" -ForegroundColor Cyan }
            else      { Write-Host "      (URL not captured yet; check $tErr)" -ForegroundColor Yellow }
        }
    }
}

# 3. Dashboard
if (-not $NoDashboard) {
    if ((Test-Running $procs["dashboard"]) -or (Test-Port $DashboardPort)) {
        Write-Host "  [skip] Dashboard already running (port $DashboardPort)"
    } else {
        Write-Host "  Starting Dashboard (port $DashboardPort)..."
        $e = Start-Svc -File $VenvPython -ArgList @("`"$DashScript`"") `
                -OutLog (Join-Path $LogDir "dashboard.out.log") -ErrLog (Join-Path $LogDir "dashboard.err.log") `
                -ProcName "python" -Extra @{ port = $DashboardPort; cmdline_match = "dashboard.py" }
        if ($e) { $procs["dashboard"] = $e; Write-Host "      [ok] PID $($e.pid)  http://localhost:$DashboardPort" -ForegroundColor Green }
    }
}

# 4. Heartbeat (opt-in)
if ($Heartbeat) {
    if (Test-Running $procs["heartbeat"]) {
        Write-Host "  [skip] Heartbeat already running"
    } else {
        Write-Host "  Starting Heartbeat agent..."
        $e = Start-Svc -File $VenvPython -ArgList @('-u', "`"$AgentScript`"") `
                -OutLog (Join-Path $LogDir "heartbeat.out.log") -ErrLog (Join-Path $LogDir "heartbeat.err.log") `
                -ProcName "python" -Extra @{ cmdline_match = "agent.py" }
        if ($e) { $procs["heartbeat"] = $e; Write-Host "      [ok] PID $($e.pid)" -ForegroundColor Green }
    }
}

# 4b. Cron daemon (opt-in; the no-admin alternative to Task Scheduler)
if ($Cron) {
    if (Test-Running $procs["cron"]) {
        Write-Host "  [skip] Cron daemon already running"
    } else {
        Write-Host "  Starting Cron daemon..."
        $e = Start-Svc -File $VenvPython -ArgList @('-u', "`"$(Join-Path $ProjectDir 'scripts\cron_daemon.py')`"") `
                -OutLog (Join-Path $LogDir "cron-daemon.out.log") -ErrLog (Join-Path $LogDir "cron-daemon.err.log") `
                -ProcName "python" -Extra @{ cmdline_match = "cron_daemon.py" }
        if ($e) { $procs["cron"] = $e; Write-Host "      [ok] PID $($e.pid)" -ForegroundColor Green }
    }
}

# 5. Telegram (opt-in, interactive -> own window)
if ($Telegram) {
    if (Test-Running $procs["telegram"]) {
        Write-Host "  [skip] Telegram already running"
    } else {
        Write-Host "  Opening Telegram channel window..."
        $cmd = "Set-Location '$ProjectDir'; claude --permission-mode auto --channels plugin:telegram@claude-plugins-official"
        $p = Start-Process -FilePath "powershell" -ArgumentList @('-NoExit','-Command', $cmd) -PassThru
        $procs["telegram"] = @{ pid = $p.Id; proc_name = "powershell"; started_at = (Get-Date -Format "s"); cmdline_match = "plugin:telegram" }
        Write-Host "      [ok] window PID $($p.Id) (close with Ctrl+C in that window)" -ForegroundColor Green
    }
}

Write-Procs $procs

Write-Host "========================================"
Write-Host "Claude Imprint is running."
if (-not $NoDashboard) { Write-Host "  Dashboard : http://localhost:$DashboardPort" }
Write-Host "  Memory API: http://localhost:$MemoryPort/mcp"
Write-Host "  Stop all  : powershell -ExecutionPolicy Bypass -File stop.ps1"
Write-Host "  Logs      : $LogDir"
