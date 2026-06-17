#!/usr/bin/env python
"""
Imprint Cron Daemon (cross-platform, no admin required).

A long-running scheduler (like the heartbeat agent) that fires the tasks in
cron-schedule.json by invoking the platform task runner. This is the simple
alternative to Windows Task Scheduler (setup-scheduler.ps1) - it only fires
while this process is alive, so start it from start.ps1 / start.sh.

    python scripts/cron_daemon.py
"""

import json
import os
import subprocess
import sys
import time
from pathlib import Path

import schedule

PROJECT_DIR = Path(__file__).resolve().parent.parent
SCHEDULE_FILE = PROJECT_DIR / "cron-schedule.json"

WEEKDAYS = {"monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"}


def _runner_cmd(name: str, prompt_path: Path):
    """Build the platform command that runs one task."""
    if os.name == "nt":
        ps1 = PROJECT_DIR / "cron-task.ps1"
        return ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
                "-File", str(ps1), name, str(prompt_path)]
    sh = PROJECT_DIR / "cron-task.sh"
    return ["bash", str(sh), name, str(prompt_path)]


def run_task(name: str, prompt_rel: str):
    """Launch a task detached so a long claude run doesn't block the loop."""
    prompt_path = PROJECT_DIR / prompt_rel
    cmd = _runner_cmd(name, prompt_path)
    kwargs = {"cwd": str(PROJECT_DIR)}
    if os.name == "nt":
        kwargs["creationflags"] = (
            subprocess.CREATE_NEW_PROCESS_GROUP | getattr(subprocess, "DETACHED_PROCESS", 0x00000008)
        )
    else:
        kwargs["start_new_session"] = True
    print(f"[{time.strftime('%Y-%m-%d %H:%M')}] launching {name}", flush=True)
    try:
        subprocess.Popen(cmd, **kwargs)
    except Exception as e:
        print(f"  ! failed to launch {name}: {e}", file=sys.stderr, flush=True)


def main():
    if not SCHEDULE_FILE.exists():
        print(f"No schedule file: {SCHEDULE_FILE}", file=sys.stderr)
        sys.exit(1)

    entries = json.loads(SCHEDULE_FILE.read_text(encoding="utf-8"))
    for e in entries:
        name = e["name"]
        prompt = e["prompt"]
        day = str(e.get("day", "daily")).lower()
        t = e["time"]
        if day == "daily":
            schedule.every().day.at(t).do(run_task, name, prompt)
        elif day in WEEKDAYS:
            getattr(schedule.every(), day).at(t).do(run_task, name, prompt)
        else:
            print(f"  skip {name}: unknown day '{day}'", file=sys.stderr)
            continue
        print(f"scheduled {name}: {day} at {t}")

    print(f"Cron daemon started; {len(schedule.get_jobs())} job(s). Ctrl+C to stop.", flush=True)
    try:
        while True:
            schedule.run_pending()
            time.sleep(30)
    except KeyboardInterrupt:
        print("\nCron daemon stopped")


if __name__ == "__main__":
    main()
