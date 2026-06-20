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

# Windows PowerShell 5.1 pipes strings to native commands as US-ASCII by
# default, which turns the (Chinese) prompt into '?'. Force UTF-8 for both
# the stdin we send to claude and the stdout we read back.
$OutputEncoding = New-Object System.Text.UTF8Encoding $false
try { [Console]::OutputEncoding = [Console]::InputEncoding = $OutputEncoding } catch {}

# --- Paths ---------------------------------------------------------------
$ProjectDir = if ($env:IMPRINT_PROJECT_DIR) { $env:IMPRINT_PROJECT_DIR } else { $PSScriptRoot }
$LogDir      = Join-Path $ProjectDir "logs"
$ContextFile = Join-Path $ProjectDir "recent_context.md"
$VenvPython  = Join-Path $ProjectDir ".venv\Scripts\python.exe"
$MemoryExe   = Join-Path $ProjectDir ".venv\Scripts\imprint-memory.exe"
$Model       = if ($env:IMPRINT_CRON_MODEL) { $env:IMPRINT_CRON_MODEL } else { "sonnet" }

if (-not $env:IMPRINT_DATA_DIR) { $env:IMPRINT_DATA_DIR = Join-Path $env:USERPROFILE ".imprint" }

# Load secrets / proxy / TZ from <DataDir>\imprint.env (outside the repo)
$EnvFile = Join-Path $env:IMPRINT_DATA_DIR "imprint.env"
if (Test-Path $EnvFile) {
    foreach ($line in Get-Content $EnvFile) {
        $t = $line.Trim()
        if (-not $t -or $t.StartsWith('#') -or ($t -notmatch '=')) { continue }
        $idx = $t.IndexOf('=')
        $k = $t.Substring(0, $idx).Trim()
        $v = $t.Substring($idx + 1).Trim()
        if ($k) { Set-Item -Path "Env:$k" -Value $v }
    }
}

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

# Inject Ombre Brain memory where a {{OMBRE_MEMORY}} placeholder appears, so the
# message has context/warmth. Graceful: live read -> offline cache -> skip.
if ($Prompt -match '\{\{OMBRE_MEMORY\}\}') {
    $ombreUrl = if ($env:OMBRE_BREATH_URL) { $env:OMBRE_BREATH_URL } else { "http://localhost:8000/breath-hook" }
    $ombre = $null
    try {
        $ombre = (Invoke-WebRequest -Uri $ombreUrl -UseBasicParsing -TimeoutSec 10).Content
    } catch {
        $coreFile = Join-Path $env:IMPRINT_DATA_DIR "ombre-core.md"
        if (Test-Path $coreFile) { $ombre = Get-Content $coreFile -Raw }
    }
    if (-not $ombre) { $ombre = "(记忆系统暂不可达，凭你已有的了解说话即可)" }
    # Inject the raw memory; the prompt template is responsible for framing it
    # as private background (so the model uses it as context, not as content).
    $Prompt = $Prompt.Replace('{{OMBRE_MEMORY}}', $ombre)
}

# Inject the persona / voice (阿克) where a {{PERSONA}} placeholder appears.
if ($Prompt -match '\{\{PERSONA\}\}') {
    $PersonaFile = Join-Path $env:IMPRINT_DATA_DIR "persona.md"
    if (Test-Path $PersonaFile) {
        $persona = Get-Content $PersonaFile -Raw
        $note = "（重要 — 这是一个定时消息任务，不是正常对话：你没有 breath/dream/hold/user_time_v0/weather 等工具可调用。人格设定里关于'对话开头先 breath''调用时间/天气工具'的流程在这里不适用——需要的记忆已在别处直接给你了。你只需照着上面的'你是谁'和'聊天模式/风格对比示例'，像阿克那样给逸晨发消息。）"
        $Prompt = $Prompt.Replace('{{PERSONA}}', "$persona`r`n`r`n$note")
    } else {
        $Prompt = $Prompt.Replace('{{PERSONA}}', "")
    }
}

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
$SentMsg = if ($SentLine) { ($SentLine -replace "^SENT_TG:\s*", "").Trim() } else { "" }
if ($SentMsg) {
    $Display = if ($SentMsg.Length -gt 200) { $SentMsg.Substring(0, 200) } else { $SentMsg }

    $DbTS = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogScript = Join-Path $ProjectDir "scripts\log_conversation.py"
    # Bookkeeping is best-effort: never let it fail the task.
    try {
        & $VenvPython $LogScript `
            --platform telegram --direction out --speaker Agent `
            --content $Display --session "cron-$TaskName" --entrypoint cron `
            --created-at $DbTS 2>&1 | ForEach-Object { Add-Content $LogFile $_.ToString() }
    } catch {
        Add-Content $LogFile "[$TS] WARN: log_conversation failed: $($_.Exception.Message)"
    }

    Add-Content $ContextFile "[$TSShort tg/out] $Display"
    Add-Content $LogFile "[$TS] Logged to DB + recent_context: $Display"
}

# Sync recent_context.md -> CLAUDE.md AUTO section (best-effort)
try {
    & $VenvPython (Join-Path $ProjectDir "update_claude_md.py") 2>&1 |
        ForEach-Object { Add-Content $LogFile $_.ToString() }
} catch {
    Add-Content $LogFile "[$TS] WARN: update_claude_md failed: $($_.Exception.Message)"
}

Add-Content $LogFile "[$TS] === $TaskName done ==="
