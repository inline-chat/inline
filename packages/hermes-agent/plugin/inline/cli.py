"""Minimal Inline setup hooks for Hermes.

The external package installer (`inline-hermes install`) handles plugin
installation. This module only provides Hermes-native setup/status hooks once
the plugin has already been discovered by Hermes.
"""
from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess

from pathlib import Path

_SIDECAR_ENTRY = Path(__file__).parent / "sidecar" / "index.mjs"
_MIN_NODE_MAJOR = 20


def gateway_setup() -> None:
    if _env_token_configured():
        print("Inline env token configured from INLINE_TOKEN/INLINE_BOT_TOKEN.")
    else:
        print("Set INLINE_TOKEN or INLINE_BOT_TOKEN in the Hermes gateway environment.")
        print("Alternatively set platforms.inline.token or inline.token in ~/.hermes/config.yaml.")
    print("Enable Inline in ~/.hermes/config.yaml:")
    print("  platforms:")
    print("    inline:")
    print("      enabled: true")
    print("Then run: inline-hermes doctor --json")


def register_cli(parser: argparse.ArgumentParser) -> None:
    subs = parser.add_subparsers(dest="inline_command", required=False)
    subs.add_parser("setup", help="Show Inline setup instructions")
    subs.add_parser("status", help="Show Inline adapter status")
    parser.set_defaults(func=dispatch)


def dispatch(args) -> int:
    command = getattr(args, "inline_command", None)
    if command is None:
        command = "status"
    if command == "setup":
        gateway_setup()
        return 0
    if command == "status":
        configured = _env_token_configured()
        print(f"Inline env token configured: {'yes' if configured else 'no'}")
        print("Hermes config token support: platforms.inline.token or inline.token")
        print(f"Inline sidecar bundled: {'yes' if _SIDECAR_ENTRY.exists() else 'no'}")
        print(f"Node available: {_node_status()}")
        if not configured:
            print("Hint: use INLINE_TOKEN/INLINE_BOT_TOKEN for env setup, or platforms.inline.token/inline.token in config.yaml.")
        print("Install diagnostics: inline-hermes doctor --json")
        return 0
    raise SystemExit(f"unknown inline command: {command}")


def _env_token_configured() -> bool:
    return bool(os.getenv("INLINE_TOKEN") or os.getenv("INLINE_BOT_TOKEN"))


def _find_node_bin() -> str | None:
    configured = os.getenv("INLINE_NODE_BIN")
    if configured:
        return configured
    try:
        from hermes_constants import find_node_executable
        found = find_node_executable("node")
        if found:
            return found
    except Exception:
        pass
    return shutil.which("node")


def _node_status() -> str:
    node_bin = _find_node_bin()
    if not node_bin:
        return "no"
    try:
        result = subprocess.run(
            [node_bin, "--version"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=5,
            check=False,
        )
    except Exception as exc:
        return f"no ({exc})"
    version = (result.stdout or result.stderr or "").strip()
    if result.returncode != 0:
        return f"no ({version or f'exited with status {result.returncode}'})"
    match = re.search(r"\bv?(\d+)(?:\.\d+){0,2}\b", version)
    major = int(match.group(1)) if match else 0
    if major < _MIN_NODE_MAJOR:
        return f"no ({version or 'unknown version'}, requires >=20)"
    return f"yes ({version})"
