<#
  Pre-Compaction Memory Flush (PreCompact hook) - Windows / PowerShell

  Fires before Claude Code compresses context. Reads the transcript and saves
  a short summary of recent conversation to the daily log, so nothing is lost.

  stdin: JSON with { session_id, transcript_path, trigger }

  Register (run once):
    claude settings add-hook PreCompact "powershell -ExecutionPolicy Bypass -File <repo>\hooks\pre-compact-flush.ps1"
#>

$ErrorActionPreference = "Continue"

$ScriptDir  = Split-Path -Parent $PSScriptRoot   # hooks\ -> repo root
$ProjectDir = $ScriptDir
$Python     = Join-Path $ProjectDir ".venv\Scripts\python.exe"
$LogDir     = Join-Path $ProjectDir "logs"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

# Read hook input from stdin
$raw = [Console]::In.ReadToEnd()
$j = $null
try { $j = $raw | ConvertFrom-Json } catch { exit 0 }

$transcript = $j.transcript_path
$trigger    = if ($j.trigger)    { $j.trigger }    else { "unknown" }
$session    = if ($j.session_id) { $j.session_id } else { "" }

# Unified memory store (same db as MCP / dashboard / hooks)
if (-not $env:IMPRINT_DATA_DIR) { $env:IMPRINT_DATA_DIR = Join-Path $env:USERPROFILE ".imprint" }

$ts = Get-Date -Format "yyyy-MM-dd HH:mm"
Add-Content (Join-Path $LogDir "compaction.log") "$ts PreCompact trigger=$trigger session=$session"

if ($transcript -and (Test-Path $transcript)) {
    $compLog = Join-Path $LogDir "compaction.log"
    # .ToString() keeps native stderr readable (PowerShell 5.1 wraps `2>>` output)
    & $Python (Join-Path $ProjectDir "hooks\pre_compact_flush.py") $transcript $trigger 2>&1 |
        ForEach-Object { Add-Content -Path $compLog -Value $_.ToString() }
}

exit 0
