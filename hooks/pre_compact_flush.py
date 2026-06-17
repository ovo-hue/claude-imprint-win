#!/usr/bin/env python
"""
Pre-compaction memory flush (extraction logic).

Called by pre-compact-flush.ps1 (Windows) / .sh with args:
    transcript_path  trigger

Reads the last messages from the session transcript and appends a short
summary to the daily log via imprint_memory, so context isn't lost when
Claude Code compresses the conversation. Uses IMPRINT_DATA_DIR for the store.
"""

import sys
import json

transcript_path = sys.argv[1] if len(sys.argv) > 1 else ""
trigger = sys.argv[2] if len(sys.argv) > 2 else "unknown"

try:
    from imprint_memory.memory_manager import daily_log

    lines = []
    with open(transcript_path, "r", encoding="utf-8") as f:
        for line in f:
            lines.append(line.strip())
    recent = lines[-50:] if len(lines) > 50 else lines

    messages = []
    for line in recent:
        try:
            entry = json.loads(line)
            role = entry.get("type", "")
            if role not in ("user", "assistant"):
                continue
            msg = entry.get("message", {})
            content = msg.get("content", "")
            if isinstance(content, str) and len(content) > 10:
                messages.append(f"[{role}] {content[:200]}")
            elif isinstance(content, list):
                for block in content:
                    if isinstance(block, dict) and block.get("type") == "text":
                        text = block.get("text", "")
                        if len(text) > 10:
                            messages.append(f"[{role}] {text[:200]}")
                            break
        except (json.JSONDecodeError, KeyError):
            continue

    if messages:
        summary_msgs = messages[-10:]
        summary = "\n".join(summary_msgs)
        daily_log(f"Compaction ({trigger}). Recent conversation:\n{summary}")
        print(f"Extracted {len(summary_msgs)} messages to log", file=sys.stderr)
    else:
        daily_log(f"Compaction ({trigger}). No extractable content.")
        print("No extractable messages", file=sys.stderr)

except Exception as e:
    print(f"Memory extraction failed: {e}", file=sys.stderr)
    try:
        from imprint_memory.memory_manager import daily_log
        daily_log(f"Compaction ({trigger}). Extraction failed: {e}")
    except Exception:
        pass
