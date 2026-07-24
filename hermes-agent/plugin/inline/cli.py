"""Minimal Inline setup hooks for Hermes.

The external package installer (`inline-hermes install`) handles plugin
installation. This module only provides Hermes-native setup/status hooks once
the plugin has already been discovered by Hermes.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys

from pathlib import Path

_SIDECAR_ENTRY = Path(__file__).parent / "sidecar" / "index.mjs"
_MIN_NODE_MAJOR = 20
_BOT_USERNAME_RE = re.compile(r"^[A-Za-z0-9_]+bot$", re.IGNORECASE)
_CLI_INSTALL_URL = "https://inline.chat/cli/install.sh"


def gateway_setup() -> None:
    """Interactively create or connect an Inline bot.

    Hermes invokes this from its messaging-platform wizard. Keep credential
    persistence inside Hermes' own config helper so profiles and file
    permissions behave exactly like the built-in Telegram setup.
    """
    from hermes_cli import gateway as hermes_gateway
    from hermes_cli import setup as hermes_setup

    hermes_setup.print_header("Inline")
    existing = (
        hermes_gateway.get_env_value("INLINE_TOKEN")
        or hermes_gateway.get_env_value("INLINE_BOT_TOKEN")
    )
    if existing:
        hermes_setup.print_info("Inline is already configured.")
        if not hermes_setup.prompt_yes_no("Reconfigure Inline?", False):
            return

    hermes_setup.print_info("How would you like to connect Hermes to Inline?")
    print()
    hermes_setup.print_info("  [1] Create a bot in Inline and paste its token")
    hermes_setup.print_info("      Go to Settings → Bots → Create a new bot.")
    hermes_setup.print_info("      https://inline.chat/docs/creating-a-bot")
    print()
    hermes_setup.print_info("  [2] Create a bot with the Inline CLI")
    hermes_setup.print_info("      Install or sign in to the CLI, then create the bot here.")
    print()

    choice = hermes_setup.prompt("Choice [1/2]", default="1").strip()
    owner_user_id: str | None = None
    token: str | None = None
    if choice == "2":
        token, owner_user_id = _create_bot_with_inline_cli(hermes_setup)
        if not token:
            print()
            hermes_setup.print_info("Falling back to an existing bot token...")

    if not token:
        token = _prompt_existing_token(hermes_setup)
    if not token:
        hermes_setup.print_warning("No token saved. Inline setup was cancelled.")
        return

    hermes_gateway.save_env_value("INLINE_TOKEN", token)
    hermes_setup.print_success("Inline bot token saved securely by Hermes.")

    if not owner_user_id:
        owner_user_id = _inline_cli_user_id(shutil.which("inline"))
    _configure_access(hermes_gateway, hermes_setup, owner_user_id)
    hermes_gateway.write_platform_config_field("inline", "enabled", True, raw=True)

    print()
    hermes_setup.print_success("💬 Inline is configured!")
    hermes_setup.print_info("Restart the gateway when prompted, then message your bot in Inline.")
    hermes_setup.print_info("Send /sethome in that chat to use it for cron results and notifications.")


def _create_bot_with_inline_cli(hermes_setup) -> tuple[str | None, str | None]:
    inline_bin = _find_inline_cli()
    if not inline_bin:
        inline_bin = _install_inline_cli(hermes_setup)
        if not inline_bin:
            hermes_setup.print_warning("Automatic bot creation is unavailable because the Inline CLI could not be installed.")
            hermes_setup.print_info("Install it from https://inline.chat/docs/cli, or use an existing bot token.")
            return None, None

    owner_user_id = _inline_cli_user_id(inline_bin)
    if not owner_user_id:
        print()
        hermes_setup.print_info("Sign in to Inline to create your Hermes bot.")
        if not hermes_setup.prompt_yes_no("Sign in now?", True):
            return None, None
        login = subprocess.run([inline_bin, "auth", "login"], check=False)
        if login.returncode != 0:
            hermes_setup.print_warning("Inline sign-in did not finish successfully.")
            return None, None
        owner_user_id = _inline_cli_user_id(inline_bin)
        if not owner_user_id:
            hermes_setup.print_warning("Inline sign-in could not be verified.")
            return None, None

    print()
    name = hermes_setup.prompt("Bot name", default="Hermes").strip()
    if not name:
        return None, owner_user_id

    while True:
        username = hermes_setup.prompt("Bot username (must end in bot)", default="hermesbot").strip().lstrip("@")
        if not _BOT_USERNAME_RE.fullmatch(username):
            hermes_setup.print_warning("Use letters, numbers, or underscores, and end the username with 'bot'.")
            continue

        payload, error = _run_inline_json(
            inline_bin,
            ["bots", "create", "--name", name, "--username", username],
        )
        token = str((payload or {}).get("token") or "").strip()
        if token:
            bot = (payload or {}).get("bot")
            bot_name = bot.get("name") if isinstance(bot, dict) else None
            hermes_setup.print_success(f"Created {bot_name or name} in Inline.")
            return token, owner_user_id

        hermes_setup.print_warning(error or "Inline could not create the bot.")
        if not hermes_setup.prompt_yes_no("Try a different username?", True):
            return None, owner_user_id


def _install_inline_cli(hermes_setup) -> str | None:
    print()
    hermes_setup.print_info("The Inline CLI is needed to create your bot automatically.")
    if not hermes_setup.prompt_yes_no("Install the Inline CLI now?", True):
        hermes_setup.print_info("Inline CLI installation skipped.")
        return None

    brew_bin = shutil.which("brew") if sys.platform == "darwin" else None
    if brew_bin:
        hermes_setup.print_info("Installing the Inline CLI with Homebrew...")
        result = subprocess.run(
            [brew_bin, "install", "--cask", "inline"],
            check=False,
        )
    else:
        curl_bin = shutil.which("curl")
        shell_bin = shutil.which("sh") or "/bin/sh"
        if not curl_bin:
            hermes_setup.print_warning("Automatic installation requires curl.")
            return None
        hermes_setup.print_info("Downloading the official Inline CLI installer...")
        try:
            download = subprocess.run(
                [curl_bin, "-fsSL", _CLI_INSTALL_URL],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=60,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            hermes_setup.print_warning(f"Could not download the Inline CLI installer: {exc}")
            return None
        if download.returncode != 0 or not download.stdout:
            hermes_setup.print_warning("Could not download the Inline CLI installer.")
            return None
        try:
            result = subprocess.run(
                [shell_bin, "-s"],
                input=download.stdout,
                timeout=180,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            hermes_setup.print_warning(f"Inline CLI installation failed: {exc}")
            return None

    if result.returncode != 0:
        hermes_setup.print_warning("The Inline CLI installer exited unsuccessfully.")
        return None

    inline_bin = _find_inline_cli()
    if not inline_bin:
        hermes_setup.print_warning("The Inline CLI was installed but could not be found on PATH.")
        return None
    try:
        verified = subprocess.run(
            [inline_bin, "--version"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=10,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        verified = None
    if verified is None or verified.returncode != 0:
        hermes_setup.print_warning("The installed Inline CLI could not be verified.")
        return None

    hermes_setup.print_success("Inline CLI installed successfully.")
    return inline_bin


def _find_inline_cli() -> str | None:
    discovered = shutil.which("inline")
    if discovered:
        return discovered
    candidates = [
        Path("/opt/homebrew/bin/inline"),
        Path("/usr/local/bin/inline"),
        Path.home() / ".local" / "bin" / "inline",
    ]
    for candidate in candidates:
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    return None


def _prompt_existing_token(hermes_setup) -> str | None:
    print()
    hermes_setup.print_info("Go to Inline → Settings → Bots → Create a new bot, then copy its token.")
    hermes_setup.print_info("Guide: https://inline.chat/docs/creating-a-bot")
    token = hermes_setup.prompt("Inline bot token", password=True).strip()
    return token or None


def _configure_access(hermes_gateway, hermes_setup, owner_user_id: str | None) -> None:
    print()
    hermes_setup.print_info("🔒 Choose who can talk to Hermes.")
    allowed: list[str] = []
    if owner_user_id:
        hermes_setup.print_success(f"Detected your Inline user ID: {owner_user_id}")
        if hermes_setup.prompt_yes_no("Allow this Inline account?", True):
            allowed.append(owner_user_id)

    extra = hermes_setup.prompt("Additional allowed user IDs (comma-separated, optional)").strip()
    for value in extra.replace(" ", "").split(","):
        if value and value not in allowed:
            allowed.append(value)

    if allowed:
        value = ",".join(allowed)
        hermes_gateway.save_env_value("INLINE_ALLOW_ALL_USERS", "false")
        hermes_gateway.save_env_value("INLINE_ALLOWED_USERS", value)
        hermes_gateway.save_env_value("INLINE_GROUP_ALLOW_FROM", value)
        hermes_gateway.save_env_value("INLINE_DM_POLICY", "allowlist")
        hermes_gateway.save_env_value("INLINE_GROUP_POLICY", "allowlist")
        hermes_setup.print_success("Only the listed Inline users can invoke Hermes.")
        return

    if hermes_setup.prompt_yes_no("Allow any Inline user who can reach the bot?", False):
        hermes_gateway.save_env_value("INLINE_ALLOW_ALL_USERS", "true")
        hermes_gateway.save_env_value("INLINE_DM_POLICY", "open")
        hermes_gateway.save_env_value("INLINE_GROUP_POLICY", "open")
        hermes_setup.print_warning("Open access enabled. Any reachable Inline user can invoke Hermes.")
    else:
        hermes_gateway.save_env_value("INLINE_ALLOW_ALL_USERS", "false")
        hermes_gateway.save_env_value("INLINE_DM_POLICY", "disabled")
        hermes_gateway.save_env_value("INLINE_GROUP_POLICY", "disabled")
        hermes_setup.print_warning("Messaging is disabled until you add allowed user IDs and re-run setup.")


def _inline_cli_user_id(inline_bin: str | None) -> str | None:
    if not inline_bin:
        return None
    payload, _ = _run_inline_json(inline_bin, ["auth", "me"])
    if not payload:
        return None
    raw = payload.get("id")
    return str(raw).strip() if raw is not None and str(raw).strip() else None


def _run_inline_json(inline_bin: str, args: list[str]) -> tuple[dict | None, str | None]:
    try:
        result = subprocess.run(
            [inline_bin, "--json", "--compact", *args],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=60,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return None, f"Inline CLI failed: {exc}"
    if result.returncode != 0:
        detail = (result.stderr or "").strip().splitlines()
        return None, detail[-1] if detail else "Inline CLI exited unsuccessfully."
    try:
        payload = json.loads(result.stdout)
    except (json.JSONDecodeError, TypeError):
        return None, "Inline CLI returned an unreadable response."
    return payload if isinstance(payload, dict) else None, None


def register_cli(parser: argparse.ArgumentParser) -> None:
    subs = parser.add_subparsers(dest="inline_command", required=False)
    subs.add_parser("setup", help="Configure Inline interactively")
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
        print(f"Inline configured: {'yes' if configured else 'no'}")
        print(f"Inline sidecar bundled: {'yes' if _SIDECAR_ENTRY.exists() else 'no'}")
        print(f"Node available: {_node_status()}")
        if not configured:
            print("Next: run `hermes inline setup` for guided bot setup.")
        print("Advanced diagnostics: inline-hermes doctor --json")
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
