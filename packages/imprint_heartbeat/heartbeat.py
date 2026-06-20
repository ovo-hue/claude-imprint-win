"""
Claude Imprint — Heartbeat Module
Periodically invokes Claude Code CLI to perform automated checks.
"""

from __future__ import annotations

import asyncio
import json
import os
import signal
import shutil
import sys
import urllib.request
from datetime import datetime, timezone, timedelta
from pathlib import Path

# ─── Config ──────────────────────────────────────────────

TZ_OFFSET = int(os.environ.get("TZ_OFFSET", 0))
LOCAL_TZ = timezone(timedelta(hours=TZ_OFFSET))

PACKAGE_DIR = Path(__file__).parent
PROJECT_DIR = PACKAGE_DIR.parent.parent  # packages/imprint_heartbeat -> project root
DATA_DIR = Path(os.environ.get("IMPRINT_DATA_DIR", str(Path.home() / ".imprint")))

GLOBAL_CLAUDE_MD = Path.home() / ".claude" / "CLAUDE.md"
HEARTBEAT_FILE = PACKAGE_DIR / "HEARTBEAT.md"
MEMORY_INDEX = DATA_DIR / "MEMORY.md"

CLAUDE_BIN = shutil.which("claude") or os.path.expanduser("~/.local/bin/claude")

HEARTBEAT_INTERVAL = int(os.environ.get("HEARTBEAT_INTERVAL", 900))
TELEGRAM_CHAT_ID = os.environ.get("TELEGRAM_CHAT_ID", "")
QUIET_START = int(os.environ.get("QUIET_START", 23))
QUIET_END = int(os.environ.get("QUIET_END", 7))

HEARTBEAT_SESSION_FILE = PROJECT_DIR / "data" / "heartbeat_session.txt"

# Paths to MCP server entry points
TELEGRAM_SERVER = PROJECT_DIR / "packages" / "imprint_telegram" / "server.py"

# Ombre Brain (claude.ai's memory system) — read its surfaced memory before
# composing a message so the heartbeat sounds like it remembers, not a template.
OMBRE_BREATH_URL = os.environ.get("OMBRE_BREATH_URL", "http://localhost:8000/breath-hook")
OMBRE_CORE_FILE = DATA_DIR / "ombre-core.md"  # offline fallback (pinned core principles)


def _get_telegram_plugin_dir() -> Path:
    """Find the latest installed Telegram plugin version."""
    base = Path.home() / ".claude/plugins/cache/claude-plugins-official/telegram"
    if base.exists():
        versions = sorted(base.iterdir(), reverse=True)
        if versions:
            return versions[0]
    return base / "0.0.1"


def now_local():
    return datetime.now(LOCAL_TZ)


def is_quiet_hours():
    hour = now_local().hour
    return hour >= QUIET_START or hour < QUIET_END


def load_session_id() -> str | None:
    if HEARTBEAT_SESSION_FILE.exists():
        return HEARTBEAT_SESSION_FILE.read_text().strip()
    return None


def save_session_id(sid: str):
    HEARTBEAT_SESSION_FILE.parent.mkdir(parents=True, exist_ok=True)
    HEARTBEAT_SESSION_FILE.write_text(sid)


def _extract_core(breath_text: str) -> str:
    """Keep only the pinned '核心准则' sections from a breath-hook payload."""
    parts = breath_text.split("\n---\n")
    core = [p for p in parts if "核心准则" in p]
    return ("\n---\n".join(core)).strip()


def _refresh_core_cache(breath_text: str):
    """Persist the pinned core principles as an offline fallback."""
    core = _extract_core(breath_text)
    if not core:
        return
    try:
        OMBRE_CORE_FILE.parent.mkdir(parents=True, exist_ok=True)
        OMBRE_CORE_FILE.write_text(core, encoding="utf-8")
    except OSError:
        pass


def fetch_ombre_memory() -> str | None:
    """Read surfaced memory from Ombre Brain (localhost). On success also
    refresh the offline core cache. On any failure, fall back to that cache.
    Returns None if no memory is available at all (graceful degradation)."""
    try:
        # Force a direct connection: Ombre is local, never via the proxy.
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(OMBRE_BREATH_URL, timeout=8) as resp:
            text = resp.read().decode("utf-8", errors="replace").strip()
        if text:
            _refresh_core_cache(text)
            return text
    except Exception as e:
        print(f"[{now_local().strftime('%H:%M:%S')}] Ombre Brain unreachable ({e}); using fallback")

    if OMBRE_CORE_FILE.exists():
        cached = OMBRE_CORE_FILE.read_text(encoding="utf-8").strip()
        return cached or None
    return None


def build_heartbeat_prompt() -> str:
    """Build heartbeat prompt with personality + rules + memory + checklist"""
    claude_md = GLOBAL_CLAUDE_MD.read_text(encoding="utf-8") if GLOBAL_CLAUDE_MD.exists() else ""
    heartbeat_md = HEARTBEAT_FILE.read_text(encoding="utf-8") if HEARTBEAT_FILE.exists() else ""
    memory_ctx = MEMORY_INDEX.read_text(encoding="utf-8") if MEMORY_INDEX.exists() else "(No memory index)"
    ombre = fetch_ombre_memory()
    ombre_section = ombre if ombre else "(记忆系统暂不可达，凭你已有的了解说话即可)"
    current_time = now_local().strftime("%Y-%m-%d %H:%M (%A)")
    quiet = is_quiet_hours()

    prompt = f"""You are executing a scheduled heartbeat check.

Current time: {current_time}
{"WARNING: Quiet hours active. Do not send messages unless urgent." if quiet else ""}

## Identity and Rules
{claude_md}

## Memory (imprint index)
{memory_ctx}

## 你和逸晨的背景记忆（私人，仅供你理解她、让语气自然；绝对不要把这些内容复述、总结、罗列或发给她）
<<<MEMORY
{ombre_section}
MEMORY>>>
（以上是给你自己看的记忆，帮助你想起你和逸晨的关系与近况。它不是要发送的内容。）

## Heartbeat Checklist
{heartbeat_md}

## 说话风格（若决定发消息，严格遵守）
- 称呼用户为「逸晨」。注意：系统别处（如 CLAUDE.md）可能称她为 Ovo / ovo-hue，但消息里**一律只用「逸晨」**。
- 自然、简洁，像日常聊天发来的一两句话，不是播报、不是记忆摘要。
- 不堆 emoji，整条消息最多一个，能不用就不用。
- 不要客套话、不要"祝你编码顺利 / 加油哦"这类套路结尾。
- 若从背景记忆里知道逸晨最近在忙什么、或有什么心情/约定，自然地提一句，让她感到被记得——但**不要把记忆内容当成消息发出去**，也不要在消息里提到"记忆""Ombre""签到"这类字眼。
- 提到天气时一句话带过，不要列表式罗列数据。

## Instructions
1. Go through the heartbeat checklist.
2. Decide if any action or notification is actually warranted.
3. If you message 逸晨, use the Telegram tool{f' (chat_id {TELEGRAM_CHAT_ID})' if TELEGRAM_CHAT_ID else ''} and follow 说话风格 above.
4. If there's new important information, save it to memory.
5. If nothing is worth saying, reply with HEARTBEAT_OK and send nothing.

Important: Don't message just to prove you're alive. Only reach out when there's something genuinely worth saying to 逸晨.
"""
    return prompt


async def run_heartbeat():
    """Execute one heartbeat cycle"""
    prompt = build_heartbeat_prompt()
    session_id = load_session_id()

    # Prompt is fed via stdin, NOT as a -p argument: on Windows the claude
    # launcher is a .cmd shim, and a huge multi-line prompt passed as an argv
    # entry gets mangled by cmd.exe, silently dropping the flags that follow
    # (e.g. --model), which then falls back to an unusable default model.
    cmd = [
        CLAUDE_BIN,
        "-p",
        "--model", os.environ.get("IMPRINT_HEARTBEAT_MODEL", "sonnet"),
        "--output-format", "json",
        "--max-budget-usd", "0.50",
    ]

    if session_id:
        cmd.extend(["--resume", session_id])

    # Build MCP config with modular servers
    mcp_servers = {
        "telegram": {
            "command": "bun",
            "args": ["run", "--cwd",
                     str(_get_telegram_plugin_dir()),
                     "--shell=bun", "--silent", "start"]
        },
        "imprint-memory": {
            "command": "imprint-memory",
            "args": []
        },
    }
    # Add telegram send server if available
    if TELEGRAM_SERVER.exists():
        mcp_servers["imprint-telegram"] = {
            "command": sys.executable,
            "args": [str(TELEGRAM_SERVER)]
        }

    # Write the MCP config to a file and pass its path (an inline JSON arg is
    # also mangled by the Windows .cmd launcher).
    mcp_config_path = DATA_DIR / "heartbeat-mcp.json"
    mcp_config_path.parent.mkdir(parents=True, exist_ok=True)
    mcp_config_path.write_text(json.dumps({"mcpServers": mcp_servers}), encoding="utf-8")
    cmd.extend(["--mcp-config", str(mcp_config_path)])
    cmd.extend(["--permission-mode", "auto"])

    env = {**os.environ}
    env.pop("CLAUDECODE", None)
    # Ensure the venv Scripts/bin dir (where imprint-memory lives) and common
    # tool dirs are on PATH for the MCP servers claude spawns. os.pathsep is
    # ';' on Windows, ':' on POSIX.
    extra_paths = [
        str(Path(sys.executable).parent),
        os.path.expanduser("~/.local/bin"),
        os.path.expanduser("~/.bun/bin"),
    ]
    env["PATH"] = os.pathsep.join(extra_paths + [env.get("PATH", "")])

    ts = now_local().strftime('%H:%M:%S')
    print(f"[{ts}] Heartbeat starting...")

    proc = None
    try:
        proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            cwd=str(PROJECT_DIR),
            env=env,
        )

        stdout, stderr = await asyncio.wait_for(
            proc.communicate(input=prompt.encode("utf-8")),
            timeout=300,
        )

        output = stdout.decode("utf-8", errors="replace").strip()

        if proc.returncode != 0:
            err = stderr.decode("utf-8", errors="replace")
            print(f"[{ts}] Heartbeat failed (rc={proc.returncode}): {err[:500]}")
            return

        try:
            result = json.loads(output)
            new_session_id = result.get("session_id")
            if new_session_id:
                save_session_id(new_session_id)

            response_text = result.get("result", "")
            if "HEARTBEAT_OK" in response_text:
                print(f"[{ts}] Heartbeat OK")
            else:
                print(f"[{ts}] Heartbeat: action taken")
        except json.JSONDecodeError:
            if "HEARTBEAT_OK" in output:
                print(f"[{ts}] Heartbeat OK")
            else:
                print(f"[{ts}] Heartbeat output: {output[:200]}")

    except asyncio.TimeoutError:
        print(f"[{ts}] Heartbeat timeout (5min)")
        if proc:
            proc.kill()
    except Exception as e:
        print(f"[{ts}] Heartbeat error: {e}")


async def heartbeat_loop():
    print(f"Heartbeat agent started")
    print(f"  Interval: {HEARTBEAT_INTERVAL}s ({HEARTBEAT_INTERVAL // 60}min)")
    print(f"  Project: {PROJECT_DIR}")
    print()

    while True:
        try:
            await run_heartbeat()
        except Exception as e:
            print(f"Heartbeat loop error: {e}")

        await asyncio.sleep(HEARTBEAT_INTERVAL)


def main():
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)

    def _request_exit(*_):
        raise SystemExit(0)

    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            # POSIX: integrate with the event loop
            loop.add_signal_handler(sig, _request_exit)
        except (NotImplementedError, AttributeError):
            # Windows event loops don't implement add_signal_handler;
            # fall back to a plain signal handler (SIGINT = Ctrl+C).
            try:
                signal.signal(sig, _request_exit)
            except (ValueError, OSError, RuntimeError):
                pass

    try:
        loop.run_until_complete(heartbeat_loop())
    except (KeyboardInterrupt, SystemExit):
        print("\nHeartbeat stopped")
    finally:
        loop.close()


if __name__ == "__main__":
    main()
