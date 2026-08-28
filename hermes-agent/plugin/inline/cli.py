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
import urllib.error
import urllib.parse
import urllib.request

from pathlib import Path

_SIDECAR_ENTRY = Path(__file__).parent / "sidecar" / "index.mjs"
_MIN_NODE_MAJOR = 20
_BOT_USERNAME_RE = re.compile(r"^[A-Za-z0-9_]+bot$", re.IGNORECASE)
_CLI_INSTALL_URL = "https://inline.chat/cli/install.sh"
_MAX_TOKEN_BYTES = 16 * 1024
_MAX_PROBE_RESPONSE_BYTES = 64 * 1024
_MACHINE_SETUP_PROTOCOL_VERSION = 1
_PROBE_USER_AGENT = "inline-hermes-agent-adapter/0.0.10"
_ENV_REFERENCE_RE = re.compile(r"^\$\{([A-Za-z_][A-Za-z0-9_]*)\}$")


class _RejectRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def _open_bot_api_probe(request: urllib.request.Request):
    return urllib.request.build_opener(_RejectRedirects()).open(request, timeout=30)


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
    configured = os.getenv("INLINE_CLI_BIN", "").strip()
    if configured:
        candidate = Path(configured).expanduser()
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
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
        _apply_access(hermes_gateway, "allowlist", owner_user_id, allowed)
        hermes_setup.print_success("Only the listed Inline users can invoke Hermes.")
        return

    if hermes_setup.prompt_yes_no("Allow any Inline user who can reach the bot?", False):
        _apply_access(hermes_gateway, "open", owner_user_id, [])
        hermes_setup.print_warning("Open access enabled. Any reachable Inline user can invoke Hermes.")
    else:
        _apply_access(hermes_gateway, "disabled", owner_user_id, [])
        hermes_setup.print_warning("Messaging is disabled until you add allowed user IDs and re-run setup.")


def _apply_access(
    hermes_gateway,
    access: str,
    owner_user_id: str | None,
    allowed_user_ids: list[str],
) -> list[str]:
    normalized: list[str] = []
    if access in ("owner", "allowlist"):
        for value in [owner_user_id, *allowed_user_ids]:
            candidate = str(value or "").strip()
            if not candidate or not candidate.isdigit() or int(candidate) <= 0:
                continue
            if candidate not in normalized:
                normalized.append(candidate)
        if not normalized:
            raise ValueError("owner or allowlist access requires a positive owner user ID")
        joined = ",".join(normalized)
        hermes_gateway.save_env_value("INLINE_ALLOW_ALL_USERS", "false")
        hermes_gateway.save_env_value("INLINE_ALLOWED_USERS", joined)
        hermes_gateway.save_env_value("INLINE_GROUP_ALLOW_FROM", joined)
        hermes_gateway.save_env_value("INLINE_DM_POLICY", "allowlist")
        hermes_gateway.save_env_value("INLINE_GROUP_POLICY", "allowlist")
        return normalized
    if access == "open":
        hermes_gateway.save_env_value("INLINE_ALLOW_ALL_USERS", "true")
        hermes_gateway.save_env_value("INLINE_ALLOWED_USERS", "")
        hermes_gateway.save_env_value("INLINE_GROUP_ALLOW_FROM", "")
        hermes_gateway.save_env_value("INLINE_DM_POLICY", "open")
        hermes_gateway.save_env_value("INLINE_GROUP_POLICY", "open")
        return normalized
    if access == "disabled":
        hermes_gateway.save_env_value("INLINE_ALLOW_ALL_USERS", "false")
        hermes_gateway.save_env_value("INLINE_ALLOWED_USERS", "")
        hermes_gateway.save_env_value("INLINE_GROUP_ALLOW_FROM", "")
        hermes_gateway.save_env_value("INLINE_DM_POLICY", "disabled")
        hermes_gateway.save_env_value("INLINE_GROUP_POLICY", "disabled")
        return normalized
    raise ValueError(f"unsupported Inline access mode: {access}")


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
    setup = subs.add_parser("setup", help="Configure Inline", description="Configure the Inline platform and its access policy.")
    setup.add_argument("--non-interactive", action="store_true", help="Run prompt-free machine setup; requires the token on stdin.")
    setup.add_argument("--token-stdin", action="store_true", help="Read one bounded Inline token from stdin instead of argv.")
    setup.add_argument("--owner-user-id", help="Positive Inline user ID that owns the configured bot.")
    setup.add_argument("--access", choices=["owner", "allowlist", "open", "disabled"], default="owner", help="Who may invoke Hermes through Inline (default: owner).")
    setup.add_argument("--allow-user", action="append", default=[], type=_positive_user_id, help="Additional positive Inline user ID to allow; repeatable.")
    setup.add_argument("--json", action="store_true", help="Print compact machine-readable setup output.")
    status = subs.add_parser("status", help="Show Inline adapter status", description="Check Inline configuration, sidecar, Node runtime, and optional credential identity.")
    status.add_argument("--json", action="store_true", help="Print compact machine-readable status output.")
    status.add_argument("--probe", action="store_true", help="Verify the configured Inline credential and bot identity.")
    parser.set_defaults(func=dispatch)


def _positive_user_id(value: str) -> str:
    value = str(value or "").strip()
    if not value.isdigit() or int(value) <= 0:
        raise argparse.ArgumentTypeError("Inline user IDs must be positive integers")
    return value


def dispatch(args) -> int:
    command = getattr(args, "inline_command", None)
    if command is None:
        command = "status"
    if command == "setup":
        if getattr(args, "non_interactive", False):
            return _machine_setup(args)
        gateway_setup()
        return 0
    if command == "status":
        return _status(args)
    raise SystemExit(f"unknown inline command: {command}")


def _machine_setup(args) -> int:
    if not getattr(args, "token_stdin", False):
        raise SystemExit("non-interactive Inline setup requires --token-stdin")
    owner_user_id = str(getattr(args, "owner_user_id", "") or "").strip()
    if not owner_user_id.isdigit() or int(owner_user_id) <= 0:
        raise SystemExit("non-interactive Inline setup requires a positive --owner-user-id")
    token = sys.stdin.read(_MAX_TOKEN_BYTES + 1)
    if len(token.encode("utf-8")) > _MAX_TOKEN_BYTES:
        raise SystemExit("Inline bot token exceeds the input limit")
    token = token.strip()
    if not token:
        raise SystemExit("Inline bot token from stdin is empty")
    from hermes_cli import gateway as hermes_gateway

    hermes_gateway.save_env_value("INLINE_TOKEN", token)
    allowed = _apply_access(
        hermes_gateway,
        getattr(args, "access", "owner"),
        owner_user_id,
        list(getattr(args, "allow_user", []) or []),
    )
    hermes_gateway.write_platform_config_field("inline", "enabled", True, raw=True)
    result = {
        "ok": True,
        "action": "inline.setup",
        "setupProtocolVersion": _MACHINE_SETUP_PROTOCOL_VERSION,
        "pluginVersion": _plugin_version(),
        "configured": True,
        "access": getattr(args, "access", "owner"),
        "ownerUserId": owner_user_id,
        "allowedUserIds": allowed,
    }
    if getattr(args, "json", False):
        print(json.dumps(result, separators=(",", ":")))
    else:
        print("Inline configured: yes")
    return 0


def _status(args) -> int:
    from hermes_cli import gateway as hermes_gateway

    raw_config = _read_inline_config(hermes_gateway)
    token = (
        hermes_gateway.get_env_value("INLINE_TOKEN")
        or hermes_gateway.get_env_value("INLINE_BOT_TOKEN")
        or _resolve_config_value(hermes_gateway, raw_config.get("token"))
    )
    configured = bool(token)
    probe_requested = bool(getattr(args, "probe", False))
    base_url = (
        hermes_gateway.get_env_value("INLINE_BASE_URL")
        or os.getenv("INLINE_BASE_URL")
        or _resolve_config_value(hermes_gateway, raw_config.get("base_url"))
        or "https://api.inline.chat"
    )
    probe = _probe_inline_token(token, base_url) if configured and probe_requested else None
    node = _node_status()
    sidecar = _sidecar_status(node)
    sidecar_bundled = bool(
        sidecar["exists"]
        and sidecar["regularFile"]
        and sidecar["readable"]
        and sidecar["size"] > 0
    )
    runtime_usable = bool(sidecar["ok"] and node["ok"])
    ready = runtime_usable and configured and (not probe_requested or bool(probe and probe.get("ok")))
    result = {
        "ok": ready,
        "ready": ready,
        "action": "inline.status",
        "setupProtocolVersion": _MACHINE_SETUP_PROTOCOL_VERSION,
        "pluginVersion": _plugin_version(),
        "configured": configured,
        "runtimeUsable": runtime_usable,
        "sidecarBundled": sidecar_bundled,
        "sidecar": sidecar,
        "node": node,
        "probeRequested": probe_requested,
        **({"probe": probe} if probe is not None else {}),
    }
    if getattr(args, "json", False):
        print(json.dumps(result, separators=(",", ":")))
    else:
        print(f"Inline configured: {'yes' if configured else 'no'}")
        print(f"Inline sidecar usable: {'yes' if sidecar['ok'] else 'no'}")
        print(f"Node available: {_node_status_text(node)}")
        print(f"Inline runtime ready: {'yes' if ready else 'no'}")
        if not configured:
            print("Next: run `hermes inline setup` for guided bot setup.")
        elif probe_requested:
            print(f"Inline credential probe: {'ready' if ready else 'failed'}")
        print("Advanced diagnostics: inline-hermes doctor --json")
    return 0 if runtime_usable and (not probe_requested or ready) else 1


def _plugin_version() -> str:
    """Read the separately installed plugin version without package-manager state."""
    try:
        for line in (Path(__file__).parent / "plugin.yaml").read_text(encoding="utf-8").splitlines():
            key, separator, value = line.partition(":")
            if separator and key.strip() == "version":
                version = value.strip().strip("\"'")
                if version:
                    return version
    except OSError:
        pass
    return "unknown"


def _read_inline_config(hermes_gateway) -> dict:
    try:
        config = hermes_gateway.read_raw_config()
    except (AttributeError, OSError, TypeError, ValueError):
        return {}
    if not isinstance(config, dict):
        return {}
    platforms = config.get("platforms")
    platform_inline = platforms.get("inline") if isinstance(platforms, dict) else None
    top_level_inline = config.get("inline")
    merged = {}
    if isinstance(top_level_inline, dict):
        merged.update(top_level_inline)
    if isinstance(platform_inline, dict):
        merged.update(platform_inline)
    return merged


def _resolve_config_value(hermes_gateway, raw) -> str:
    value = str(raw or "").strip()
    match = _ENV_REFERENCE_RE.fullmatch(value)
    if match:
        name = match.group(1)
        return str(hermes_gateway.get_env_value(name) or os.getenv(name) or "").strip()
    return value


def _probe_inline_token(token: str, base_url: str = "https://api.inline.chat") -> dict:
    try:
        base_url = str(base_url or "https://api.inline.chat").rstrip("/")
        parsed = urllib.parse.urlsplit(base_url)
        if parsed.scheme not in ("http", "https") or not parsed.netloc or parsed.query or parsed.fragment:
            raise ValueError("invalid Inline base URL")
        request = urllib.request.Request(
            f"{base_url}/v1/getMe",
            headers={
                "Accept": "application/json",
                "Authorization": f"Bearer {token}",
                "User-Agent": _PROBE_USER_AGENT,
            },
            method="GET",
        )
        with _open_bot_api_probe(request) as response:
            raw = response.read(_MAX_PROBE_RESPONSE_BYTES + 1)
    except urllib.error.HTTPError as exc:
        if exc.code in (401, 403):
            return {"ok": False, "errorKind": "invalid_credential", "error": "Inline rejected the configured credential."}
        return {"ok": False, "errorKind": "unavailable", "error": "Inline API credential probe failed."}
    except ValueError:
        return {"ok": False, "errorKind": "invalid_config", "error": "Inline API base URL is invalid."}
    except (OSError, TimeoutError, urllib.error.URLError):
        return {"ok": False, "errorKind": "unavailable", "error": "Inline API credential probe could not run."}
    if len(raw) > _MAX_PROBE_RESPONSE_BYTES:
        return {"ok": False, "errorKind": "invalid_response", "error": "Inline API credential probe returned too much data."}
    try:
        payload = json.loads(raw)
    except (json.JSONDecodeError, TypeError, UnicodeDecodeError):
        return {"ok": False, "errorKind": "invalid_response", "error": "Inline API credential probe returned unreadable output."}
    if not isinstance(payload, dict) or payload.get("ok") is not True:
        return {"ok": False, "errorKind": "invalid_response", "error": "Inline API credential probe returned an unsuccessful response."}
    result = payload.get("result")
    user = result.get("user") if isinstance(result, dict) else None
    if not isinstance(user, dict):
        return {"ok": False, "errorKind": "invalid_response", "error": "Inline API credential probe returned no user identity."}
    raw_id = user.get("id") if isinstance(user, dict) else None
    bot_user_id = str(raw_id).strip() if raw_id is not None else ""
    if not bot_user_id.isdigit() or int(bot_user_id) <= 0:
        return {"ok": False, "errorKind": "invalid_response", "error": "Inline API credential probe returned no user identity."}
    username = str(user.get("username") or "").strip().lstrip("@")
    return {
        "ok": True,
        "botUserId": bot_user_id,
        **({"botUsername": username} if username else {}),
    }


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


def _node_status() -> dict:
    node_bin = _find_node_bin()
    if not node_bin:
        return {
            "ok": False,
            "path": None,
            "version": None,
            "major": None,
            "minimumMajor": _MIN_NODE_MAJOR,
            "error": "Node.js was not found.",
        }
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
        return {
            "ok": False,
            "path": node_bin,
            "version": None,
            "major": None,
            "minimumMajor": _MIN_NODE_MAJOR,
            "error": f"Node.js could not run: {exc}",
        }
    version = (result.stdout or result.stderr or "").strip()
    if result.returncode != 0:
        return {
            "ok": False,
            "path": node_bin,
            "version": version or None,
            "major": None,
            "minimumMajor": _MIN_NODE_MAJOR,
            "error": f"Node.js exited with status {result.returncode}.",
        }
    match = re.search(r"\bv?(\d+)(?:\.\d+){0,2}\b", version)
    major = int(match.group(1)) if match else None
    ok = major is not None and major >= _MIN_NODE_MAJOR
    return {
        "ok": ok,
        "path": node_bin,
        "version": version or None,
        "major": major,
        "minimumMajor": _MIN_NODE_MAJOR,
        "error": None if ok else f"Node.js {version or 'version'} is incompatible; requires >= {_MIN_NODE_MAJOR}.",
    }


def _sidecar_status(node: dict) -> dict:
    try:
        info = _SIDECAR_ENTRY.stat()
        exists = True
        regular_file = _SIDECAR_ENTRY.is_file()
        readable = os.access(_SIDECAR_ENTRY, os.R_OK)
        size = info.st_size
    except OSError:
        exists = False
        regular_file = False
        readable = False
        size = 0

    syntax_checked = False
    syntax_ok = False
    error = None
    if not exists:
        error = "The packaged Inline sidecar is missing."
    elif not regular_file or not readable or size <= 0:
        error = "The packaged Inline sidecar is not a readable non-empty file."
    elif node.get("ok"):
        syntax_checked = True
        try:
            checked = subprocess.run(
                [str(node["path"]), "--check", str(_SIDECAR_ENTRY)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=10,
                check=False,
            )
            syntax_ok = checked.returncode == 0
            if not syntax_ok:
                error = "The packaged Inline sidecar failed Node.js syntax validation."
        except (OSError, subprocess.TimeoutExpired):
            error = "The packaged Inline sidecar could not be validated by Node.js."
    else:
        error = "The packaged Inline sidecar cannot run without compatible Node.js."

    return {
        "ok": bool(exists and regular_file and readable and size > 0 and syntax_checked and syntax_ok),
        "exists": exists,
        "regularFile": regular_file,
        "readable": readable,
        "size": size,
        "syntaxChecked": syntax_checked,
        "syntaxOk": syntax_ok,
        "error": error,
    }


def _node_status_text(node: dict) -> str:
    if node.get("ok"):
        return f"yes ({node.get('version') or 'unknown version'})"
    return f"no ({node.get('error') or 'unknown error'})"
