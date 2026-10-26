"""Per-profile settings and state for the Inline platform.

Since Hermes 0.22 one gateway process can serve every profile. Credentials and
settings then come from the routed profile's scope rather than ``os.environ``,
and anything written to disk has to be owned by one profile and one bot.
"""

from __future__ import annotations

import hashlib
import os
from pathlib import Path
from typing import Optional


def inline_env(name: str, default: Optional[str] = None) -> Optional[str]:
    """Read an INLINE_* setting from the active profile, falling back to the process env on older hosts."""
    try:
        from agent.secret_scope import get_secret
    except ImportError:
        return os.getenv(name, default)
    try:
        return get_secret(name, default)
    except Exception as exc:
        # A multiplexed host with no profile scope fails closed rather than
        # handing out another profile's value.
        if type(exc).__name__ == "UnscopedSecretError":
            return default
        raise


def hermes_home() -> Path:
    """The Hermes home of the profile this code is running for."""
    try:
        from hermes_constants import get_hermes_home

        return Path(get_hermes_home())
    except Exception:
        return Path(os.getenv("HERMES_HOME") or Path.home() / ".hermes").expanduser()


def legacy_state_dir() -> Path:
    """Where releases before the profile split kept state, whatever the profile."""
    return Path.home() / ".hermes" / "inline"


def state_dir() -> Path:
    return hermes_home() / "inline"


def bot_state_key(base_url: str, token: str) -> str:
    """A stable, non-secret name for one bot on one API.

    Inline bot tokens start with the bot's user id, so the name survives token
    rotation; anything else falls back to a hash of the token.
    """
    server = hashlib.sha256(base_url.encode("utf-8")).hexdigest()[:8]
    bot_id, separator, _ = token.partition(":")
    if separator and bot_id.isdigit():
        return f"bot{bot_id}-{server}"
    return hashlib.sha256(f"{base_url}\n{token}".encode("utf-8")).hexdigest()[:16]


def multiplex_active() -> bool:
    """Whether this process serves several Hermes profiles (Hermes 0.22+)."""
    try:
        from agent.secret_scope import is_multiplex_active
    except ImportError:
        return False
    try:
        return bool(is_multiplex_active())
    except Exception:
        return False


def may_adopt_legacy_state() -> bool:
    """Whether the pre-split shared state file can be trusted as this adapter's own.

    The legacy file never recorded which bot wrote it. Only the classic install,
    the default profile in a gateway serving just that profile, plausibly owns it.
    Everyone else, including every profile of a multiplexed gateway, starts from
    now: that can miss messages sent while the gateway was down, but never replays
    answered ones. The old file stays in place for recovery.
    """
    default_root = (Path.home() / ".hermes").resolve()
    return hermes_home().resolve() == default_root and not multiplex_active()
