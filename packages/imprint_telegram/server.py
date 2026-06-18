#!/usr/bin/env python3
"""
imprint-telegram — MCP Server
Send Telegram messages and files via Bot API.

Usage:
  python3 server.py    # stdio mode

Requires env vars: TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID
"""

import os
import sys
import uuid
import urllib.request
import urllib.parse
from pathlib import Path

# Verify TLS against the OS certificate store so HTTPS works behind a
# TLS-intercepting proxy (common with xray/v2ray + system security tools on
# Windows). No-op on systems where the default store already suffices.
try:
    import truststore
    truststore.inject_into_ssl()
except Exception:
    pass

from mcp.server.fastmcp import FastMCP

mcp = FastMCP("imprint-telegram")


@mcp.tool()
def send_telegram(text: str, chat_id: str = "") -> str:
    """Send a Telegram message directly via Bot API. Millisecond delivery.
    Leave chat_id empty to use the default (TELEGRAM_CHAT_ID env var)."""
    bot_token = os.environ.get("TELEGRAM_BOT_TOKEN", "")
    if not bot_token:
        return "Error: TELEGRAM_BOT_TOKEN not configured"
    target = chat_id or os.environ.get("TELEGRAM_CHAT_ID", "")
    if not target:
        return "Error: No chat_id specified and TELEGRAM_CHAT_ID not set"

    url = f"https://api.telegram.org/bot{bot_token}/sendMessage"
    data = urllib.parse.urlencode({
        "chat_id": target, "text": text,
    }).encode()
    try:
        req = urllib.request.Request(url, data=data)
        with urllib.request.urlopen(req, timeout=10) as resp:
            import json
            result = json.loads(resp.read())
            if result.get("ok"):
                return "Message sent to Telegram"
            return f"Error: Telegram API: {result.get('description', 'unknown')}"
    except Exception as e:
        return f"Error: Send failed: {str(e)}"


@mcp.tool()
def send_telegram_photo(file_path: str, caption: str = "", chat_id: str = "") -> str:
    """Send a local file/photo to Telegram. Supports images (jpg/png/gif/webp) and any file type.
    file_path: absolute path to local file. caption: optional description."""
    bot_token = os.environ.get("TELEGRAM_BOT_TOKEN", "")
    if not bot_token:
        return "Error: TELEGRAM_BOT_TOKEN not configured"
    target = chat_id or os.environ.get("TELEGRAM_CHAT_ID", "")
    if not target:
        return "Error: No chat_id specified"

    fp = Path(file_path)
    if not fp.exists():
        return f"Error: File not found: {file_path}"
    size_mb = fp.stat().st_size / (1024 * 1024)

    ext = fp.suffix.lower()
    is_photo = ext in ('.jpg', '.jpeg', '.png', '.gif', '.webp')
    if is_photo and size_mb > 10:
        return f"Error: Photo too large ({size_mb:.1f}MB), Telegram limit is 10MB"
    if size_mb > 50:
        return f"Error: File too large ({size_mb:.1f}MB), Telegram limit is 50MB"

    method = "sendPhoto" if is_photo else "sendDocument"
    field_name = "photo" if is_photo else "document"
    url = f"https://api.telegram.org/bot{bot_token}/{method}"

    boundary = uuid.uuid4().hex
    file_data = fp.read_bytes()
    parts = []
    for k, v in [("chat_id", target), ("caption", caption), ("parse_mode", "Markdown")]:
        parts.append(f"--{boundary}\r\nContent-Disposition: form-data; name=\"{k}\"\r\n\r\n{v}".encode())
    parts.append(
        f"--{boundary}\r\nContent-Disposition: form-data; name=\"{field_name}\"; filename=\"{fp.name}\"\r\n"
        f"Content-Type: application/octet-stream\r\n\r\n".encode() + file_data
    )
    body = b"\r\n".join(parts) + f"\r\n--{boundary}--\r\n".encode()

    try:
        req = urllib.request.Request(url, data=body)
        req.add_header("Content-Type", f"multipart/form-data; boundary={boundary}")
        with urllib.request.urlopen(req, timeout=30) as resp:
            import json
            result = json.loads(resp.read())
            if result.get("ok"):
                return f"File sent to Telegram: {fp.name}"
            return f"Error: Telegram API: {result.get('description', 'unknown')}"
    except Exception as e:
        return f"Error: Send failed: {str(e)}"


if __name__ == "__main__":
    mcp.run(transport="stdio")
