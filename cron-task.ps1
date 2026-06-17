<#
  Imprint Cron Task Runner (Windows / PowerShell)

  Runs a single Claude CLI task with the imprint MCP servers, then logs any
  Telegram message it reported. Invoked by Windows Task Scheduler (see
  setup-scheduler.ps1) or by the schedule daemon (scripts/cron_daemon.py).

  Usage:
    powershell -ExecutionPolicy Bypass -File cron-task.ps1 <task-name> <prompt-file>

  Design:
    - Runs from $HOME so the project-level .mcp.json is not auto-loaded
    - Picks cron-mcp-full.json if present (telegram + utils), else cron-mcp.json
    - Rewrites that config at runtime to absolute venv paths (Windows has no
      python3, and relative server paths would not resolve from $HOME)
    - Passes --model (default sonnet) because headless `claude -p` otherwise
      falls back to a model this machine cannot use
    - --max-budget-usd caps cost; the CLI exits on its own
#>

param(
    [Parameter(Mandatory)][string]$TaskName,
    [Parameter(Mandatory)][string]$PromptFile
)

$ErrorActionPreference = "Stop"

# --- Paths ---------------------------------------------------------------
$ProjectDir = if ($env:IMPRINT_PROJECT_DIR) { $env:IMPRINT_PROJECT_DIR } else { $PSScriptRoot }
$LogDir      = Join-Path $ProjectDir "logs"
$ContextFile = Join-Path $ProjectDir "recent_context.md"
$VenvPython  = Join-Path $ProjectDir ".venv\Scripts\python.exe"
$MemoryExe   = Join-Path $ProjectDir ".venv\Scripts\imprint-memory.exe"
$Model       = if ($env:IMPRINT_CRON_MODEL) { $env:IMPRINT_CRON_MODEL } else { "sonnet" }

if (-not $env:IMPRINT_DATA_DIR) { $env:IMPRINT_DATA_DIR = Join-Path $env:USERPROFILE ".imprint" }

# claude is a .cmd shim; resolve it (Task Scheduler has a minimal PATH)
$ClaudeBin = (Get-Command claude -ErrorAction SilentlyContinue).Source
if (-not $ClaudeBin) { $ClaudeBin = Join-Path $env:APPDATA "npm\claude.cmd" }

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$LogFile = Join-Path $LogDir "cron-$TaskName.log"
$TS      = Get-Date -Format "yyyy-MM-dd HH:mm"
$TSShort = Get-Date -Format "MM-dd HH:mm"

Add-Content $LogFile "[$TS] === $TaskName start ==="

if (-not (Test-Path $PromptFile)) {
    Add-Content $LogFile "[$TS] ERROR: prompt file not found: $PromptFile"
    exit 1
}
$Prompt = Get-Content $PromptFile -Raw

# --- Auth ----------------------------------------------------------------
# Max Plan users: store the OAuth token in ~/.claude/cron-token
$TokenFile = Join-Path $env:USERPROFILE ".claude\cron-token"
if (Test-Path $TokenFile) {
    $env:CLAUDE_CODE_OAUTH_TOKEN = (Get-Content $TokenFile -Raw).Trim()
    # $env:ANTHROPIC_API_KEY = (Get-Content $TokenFile -Raw).Trim()  # for API-key auth
}

# --- Build a runtime MCP config with absolute venv paths -----------------
$SrcConfig = if (Test-Path (Join-Path $ProjectDir "cron-mcp-full.json")) {
    Join-Path $ProjectDir "cron-mcp-full.json"
} else {
    Join-Path $ProjectDir "cron-mcp.json"
}
$cfg = Get-Content $SrcConfig -Raw | ConvertFrom-Json
foreach ($name in @($cfg.mcpServers.PSObject.Properties.Name)) {
    $srv = $cfg.mcpServers.$name
    if ($srv.command -eq "imprint-memory") {
        $srv.command = $MemoryExe
    } elseif ($srv.command -in @("python", "python3")) {
        $srv.command = $VenvPython
        if ($srv.args) {
            $srv.args = @($srv.args | ForEach-Object {
                if ($_ -match '\.py$' -and -not [System.IO.Path]::IsPathRooted($_)) { Join-Path $ProjectDir $_ } else { $_ }
            })
        }
    }
}
$RuntimeConfig = Join-Path $LogDir "cron-mcp-runtime.json"
($cfg | ConvertTo-Json -Depth 6) | Set-Content -Path $RuntimeConfig -Encoding UTF8

# --- Run claude CLI (from $HOME to avoid loading project .mcp.json) -------
$TmpOut = [System.IO.Path]::GetTempFileName()
Push-Location $env:USERPROFILE
try {
    $Prompt | & $ClaudeBin -p `
        --model $Model `
        --mcp-config $RuntimeConfig `
        --dangerously-skip-permissions `
        --max-budget-usd 0.50 `
        --output-format text 2>&1 |
        ForEach-Object { $_.ToString() } | Set-Content -Path $TmpOut -Encoding UTF8
} catch {
    Add-Content $LogFile "[$TS] claude invocation error: $($_.Exception.Message)"
} finally {
    Pop-Location
}

$Output = if (Test-Path $TmpOut) { Get-Content $TmpOut -Raw } else { "" }
Remove-Item $TmpOut -ErrorAction SilentlyContinue

$OutputPreview = if ($Output -and $Output.Length -gt 200) { $Output.Substring(0, 200) } else { $Output }
Add-Content $LogFile "[$TS] Output: $OutputPreview"

# --- If a Telegram message was sent, log it ------------------------------
# The prompt instructs the AI to print a line: SENT_TG: <message>
$SentLine = ($Output -split "`n") | Where-Object { $_ -match "^SENT_TG:" } | Select-Object -First 1
if ($SentLine) {
    $SentMsg = ($SentLine -replace "^SENT_TG:\s*", "").Trim()
    $Display = if ($SentMsg.Length -gt 200) { $SentMsg.Substring(0, 200) } else { $SentMsg }

    $DbTS = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogScript = Join-Path $ProjectDir "scripts\log_conversation.py"
    & $VenvPython $LogScript `
        --platform telegram --direction out --speaker Agent `
        --content $Display --session "cron-$TaskName" --entrypoint cron `
        --created-at $DbTS 2>&1 | ForEach-Object { Add-Content $LogFile $_.ToString() }

    Add-Content $ContextFile "[$TSShort tg/out] $Display"
    Add-Content $LogFile "[$TS] Logged to DB + recent_context: $Display"
}

# Sync recent_context.md -> CLAUDE.md AUTO section
& $VenvPython (Join-Path $ProjectDir "update_claude_md.py") 2>&1 |
    ForEach-Object { Add-Content $LogFile $_.ToString() }

Add-Content $LogFile "[$TS] === $TaskName done ==="
