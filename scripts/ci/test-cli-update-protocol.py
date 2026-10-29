#!/usr/bin/env python3
"""Exercise the shipped updater command boundary without touching a real account."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

binary = Path(sys.argv[1] if len(sys.argv) > 1 else "target/debug/inline").resolve()
with tempfile.TemporaryDirectory(prefix="inline-update-protocol-") as directory:
    root = Path(directory)
    # Deliberately invalid auth files prove dispatch precedes auth parsing.
    auth = root / "secrets.json"
    state = root / "state.json"
    auth.write_bytes(b"authentication sentinel\n")
    state.write_bytes(b"account and receipts sentinel\n")
    env = {**os.environ, "INLINE_DATA_DIR": str(root), "INLINE_CLI_TELEMETRY": "off", "INLINE_DISABLE_AUTOUPDATE": "1", "INLINE_STATE_PATH": str(state), "INLINE_SECRETS_PATH": str(auth)}
    def call(*args):
        return json.loads(subprocess.check_output([str(binary), *args, "--json"], env=env, timeout=15))
    configured = call("update", "config", "--auto", "off", "--app-channel", "alpha")
    assert configured["autoUpdate"] is False and configured["channel"] == "alpha"
    revision = configured["revision"]
    repeated = call("update", "config", "--app-channel", "alpha")
    assert repeated["revision"] == revision
    call("update", "config", "--channel", "stable")
    manual = call("update", "config", "--app-channel", "alpha")
    assert manual["channel"] == "stable" and manual["followsApp"] is False
    following = call("update", "config", "--follow-app", "--app-channel", "alpha")
    assert following["channel"] == "alpha" and following["followsApp"] is True
    background = call("update", "--background")
    assert background["autoUpdate"] is False
    assert background["lastAttempt"] is None
    assert background["schemaVersion"] == 1
    assert auth.read_bytes() == b"authentication sentinel\n"
    assert state.read_bytes() == b"account and receipts sentinel\n"
    print("Updater status/config/background protocol preserves existing auth and explicit opt-out.")
