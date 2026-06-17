<#
  Post-Response hook (Stop event) - Windows / PowerShell

  Fires after every Claude response. Reads new messages from the session
  transcript, writes them to conversation_log, regenerates recent_context.md,
  syncs the CLAUDE.md AUTO section, and compresses recent_context.md if large.

  stdin: JSON with { session_id, transcript_path }

  Register (run once):
    claude settings add-hook Stop "powershell -ExecutionPolicy Bypass -File <repo>\hooks\post-response.ps1"
#>

$ErrorActionPreference = "Continue"

$ProjectDir = Split-Path -Parent $PSScriptRoot   # hooks\ -> repo root
$Python     = Join-Path $ProjectDir ".venv\Scripts\python.exe"
$LogDir     = Join-Path $ProjectDir "logs"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$HookLog    = Join-Path $LogDir "post-response.log"

# Read hook input from stdin
$raw = [Console]::In.ReadToEnd()
$j = $null
try { $j = $raw | ConvertFrom-Json } catch { exit 0 }

$transcript = $j.transcript_path
$session    = if ($j.session_id) { $j.session_id } else { "" }
if (-not $transcript -or -not (Test-Path $transcript)) { exit 0 }

# Unified memory store (same db as MCP / dashboard / pre-compact hook)
if (-not $env:IMPRINT_DATA_DIR) { $env:IMPRINT_DATA_DIR = Join-Path $env:USERPROFILE ".imprint" }

# Run a child command, appending its merged output to the log as plain text.
# (PowerShell 5.1 wraps native stderr from `2>>` as ErrorRecords; .ToString()
#  keeps the log readable.)
function Invoke-Logged {
    param([string]$File, [string[]]$Args, [string]$Log)
    & $File @Args 2>&1 | ForEach-Object { Add-Content -Path $Log -Value $_.ToString() }
}

# 1. Process new messages -> conversation_log + recent_context.md
Invoke-Logged -File $Python -Log $HookLog -Args @(
    (Join-Path $ProjectDir "hooks\post_response_processor.py"), $transcript, $session, $ProjectDir)

# 2. Sync recent_context.md -> CLAUDE.md AUTO section
Invoke-Logged -File $Python -Log $HookLog -Args @((Join-Path $ProjectDir "update_claude_md.py"))

# 3. Compress recent_context.md if it has > 120 message lines (run in background)
$ContextFile = Join-Path $ProjectDir "recent_context.md"
if (Test-Path $ContextFile) {
    $msgLines = @(Select-String -Path $ContextFile -Pattern '^\[' -ErrorAction SilentlyContinue).Count
    if ($msgLines -gt 120) {
        $compress = Join-Path $ProjectDir "scripts\compress_context.py"
        if (Test-Path $compress) {
            Start-Process -FilePath $Python -ArgumentList @("`"$compress`"", "`"$ContextFile`"") `
                -RedirectStandardOutput (Join-Path $LogDir "compress.out.log") `
                -RedirectStandardError  (Join-Path $LogDir "compress.err.log") `
                -WindowStyle Hidden | Out-Null
        }
    }
}

exit 0
