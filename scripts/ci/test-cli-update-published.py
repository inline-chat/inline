#!/usr/bin/env python3
"""Opt-in CI smoke: released pre-updater clients -> first signed updater -> candidate.

All executable, account and receipt files live in a disposable directory. No
service is installed or restarted. Only public release storage is contacted;
the API/realtime endpoints point at an unused loopback port.
"""
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import sqlite3
import subprocess
import sys
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[2]
BASE = "https://public-assets.inline.chat/cli"
FIRST_UPDATER = "0.7.19-alpha.8"
BASELINES = ["0.7.18", "0.7.19-alpha.7"]
API = "https://127.0.0.1:9"
CANDIDATE = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / "target/debug/inline").resolve()


def command(args, *, env=None, expected=0, timeout=180, data=None):
    result = subprocess.run(args, env=env, input=data, capture_output=True, timeout=timeout)
    if (expected == 0 and result.returncode != 0) or (expected != 0 and result.returncode == 0):
        raise AssertionError(f"Command {args[:3]} returned {result.returncode}: "
                             + result.stderr.decode(errors="replace")[-3000:])
    return result.stdout


def download(url, destination, maximum):
    command(["curl", "--fail", "--silent", "--show-error", "--location",
             "--proto", "=https", "--proto-redir", "=https", "--connect-timeout", "10",
             "--max-time", "120", "--retry", "2", "--max-filesize", str(maximum),
             url, "-o", str(destination)], timeout=400)
    assert destination.stat().st_size <= maximum


def metadata(path, directory):
    file = directory / path.replace("/", "_")
    download(f"{BASE}/{path}", file, 262144)
    return file.read_bytes()


def digest(path):
    with path.open("rb") as file:
        return hashlib.file_digest(file, "sha256").hexdigest()


def released_binary(version, target, manifest, directory):
    assert manifest["version"] == version
    identity = manifest["targets"][target]
    archive = directory / f"{version}-{target}.tar.gz"
    download(identity["url"], archive, 100 * 1024 * 1024)
    assert digest(archive) == identity["sha256"]
    if identity.get("size") is not None:
        assert archive.stat().st_size == identity["size"]
    binary = archive.with_suffix(".inline")
    found = False
    with tarfile.open(archive, "r:gz") as bundle:
        for member in bundle:
            assert not found and member.name in ("inline", "./inline")
            assert member.isfile() and 0 < member.size <= 200 * 1024 * 1024
            with bundle.extractfile(member) as source, binary.open("wb") as destination:
                shutil.copyfileobj(source, destination)
            found = True
    assert found
    binary.chmod(0o755)
    if platform.system() == "Darwin":
        command(["/usr/bin/codesign", "--verify", "--strict", "--all-architectures",
                 '-R=anchor apple generic and identifier "chat.inline.cli" and certificate leaf[subject.OU] = "2487AN8AL4"', str(binary)])
    return binary


def exercise(baseline, old, updater, target, directory):
    case = directory / f"case-{baseline}-{target}"
    case.mkdir()
    home = case / "home"
    home.mkdir()
    launcher = case / "inline"
    shutil.copy2(old, launcher)
    auth = case / "secrets.json"
    state = case / "state.json"
    auth.write_text(json.dumps({"apiBaseUrl": API, "deviceId": "qualification-only"}))
    state.write_text(json.dumps({"apiBaseUrl": API, "currentUser": None, "updatedAt": 123,
                                 "updateChannel": "alpha" if "alpha" in baseline else None}))
    receipts = case / "delivery.sqlite"
    with sqlite3.connect(receipts) as db:
        db.execute("CREATE TABLE receipts (id TEXT PRIMARY KEY)")
        db.execute("INSERT INTO receipts VALUES ('already-delivered')")
    env = {key: value for key, value in os.environ.items() if not key.startswith("INLINE_")}
    env.update(HOME=str(home), INLINE_DATA_DIR=str(case), INLINE_STATE_PATH=str(state),
               INLINE_SECRETS_PATH=str(auth), INLINE_CLI_TELEMETRY="off", INLINE_DISABLE_AUTOUPDATE="1",
               INLINE_API_BASE_URL=API, INLINE_REALTIME_URL="wss://127.0.0.1:9",
               INLINE_RELEASE_MANIFEST_URL=f"{BASE}/v{FIRST_UPDATER}/manifest.json")

    def call(binary, *args, environment=env, expected=0):
        return command([str(binary), *args], env=environment, expected=expected, timeout=240)

    assert call(launcher, "--version").strip() == f"inline {baseline}".encode()
    check = json.loads(call(launcher, "update", "--check", "--json"))
    assert check["latest_version"] == FIRST_UPDATER and check["update_available"]
    canaries = {path: path.read_bytes() for path in [auth, receipts]}
    call(launcher, "update", "--json")
    assert digest(launcher) == digest(updater)
    assert call(launcher, "--version").strip() == f"inline {FIRST_UPDATER}".encode()
    # Older channel-aware clients may save their channel during the upgrade.
    # Every updater command after that boundary must preserve those account bytes.
    assert json.loads(state.read_bytes())["updatedAt"] == 123
    canaries[state] = state.read_bytes()
    registered = json.loads(call(launcher, "update", "config", "--register", "--json"))
    assert registered["autoUpdate"] and registered["channel"] == "alpha"
    assert registered["installationMethod"] == "managed"
    parsed = json.loads(call(CANDIDATE, "update", "status", "--json"))
    assert parsed["launchers"] == registered["launchers"]
    assert parsed["autoUpdate"] and parsed["channel"] == "alpha"
    # The candidate must retain off across app-channel changes and the old engine.
    call(CANDIDATE, "update", "config", "--auto", "off", "--json")
    followed = json.loads(call(CANDIDATE, "update", "config", "--follow-app", "--app-channel", "stable", "--json"))
    assert not followed["autoUpdate"] and followed["channel"] == "stable"
    assert not json.loads(call(launcher, "update", "status", "--json"))["autoUpdate"]

    signed = {**env, "INLINE_RELEASE_MANIFEST_URL": f"{BASE}/v{FIRST_UPDATER}/channel.alpha.json"}
    # Bad release order/channel metadata and an unavailable feed cannot replace
    # the public launcher or reset auth; retry state must remain actionable.
    before = digest(launcher)
    call(CANDIDATE, "update", "--channel", "stable", "--json", environment=signed, expected=1)
    rejected = json.loads(call(CANDIDATE, "update", "status", "--json"))
    assert rejected["failure"] == "manifest_contract"
    unavailable = {**env, "INLINE_RELEASE_MANIFEST_URL": "https://127.0.0.1:9/not-published.json"}
    call(CANDIDATE, "update", "--channel", "alpha", "--json", environment=unavailable, expected=1)
    failed = json.loads(call(CANDIDATE, "update", "status", "--json"))
    assert failed["failure"] == "network" and failed["retryAt"] is not None
    # Restoring the authentic feed clears backoff, and an explicit current
    # update enrolls the invoking candidate without turning the opt-out on.
    recovered = json.loads(call(CANDIDATE, "update", "--channel", "alpha", "--json", environment=signed))
    assert recovered["failure"] is None and recovered["retryAt"] is None
    assert str(CANDIDATE) in recovered["launchers"] and not recovered["autoUpdate"]
    normal = {key: value for key, value in env.items() if key not in ("INLINE_RELEASE_MANIFEST_URL", "INLINE_DISABLE_AUTOUPDATE")}
    idle = json.loads(call(launcher, "update", "--background", "--json", environment=normal))
    assert not idle["autoUpdate"] and idle["lastAttempt"] == recovered["lastAttempt"]
    assert digest(launcher) == before
    for path, content in canaries.items():
        assert path.read_bytes() == content, f"Account/receipt canary changed: {path.name}"
    print(f"PASS {target}: {baseline} -> {FIRST_UPDATER} -> candidate; enrollment, opt-out, feed failure/recovery, account preservation", flush=True)


def main():
    system = platform.system()
    targets = ["aarch64-apple-darwin"] if system == "Darwin" else ["x86_64-unknown-linux-gnu", "x86_64-unknown-linux-musl"]
    assert (system == "Darwin" and platform.machine() == "arm64") or (system == "Linux" and platform.machine() == "x86_64")
    assert CANDIDATE.is_file()
    with tempfile.TemporaryDirectory(prefix="inline-released-upgrade-") as temporary:
        directory = Path(temporary)
        signed = metadata(f"v{FIRST_UPDATER}/channel.alpha.json", directory)
        verifier = "import {authenticatedChannelVersion} from './scripts/cli-release-signing.ts'; console.log(JSON.stringify(await authenticatedChannelVersion(await Bun.stdin.text(),'alpha')));"
        release = json.loads(command(["bun", "--no-env-file", "-e", verifier], data=signed))
        manifests = {v: json.loads(metadata(f"v{v}/manifest.json", directory)) for v in BASELINES}
        for target in targets:
            updater = released_binary(FIRST_UPDATER, target, release, directory)
            for baseline in BASELINES:
                old = released_binary(baseline, target, manifests[baseline], directory)
                exercise(baseline, old, updater, target, directory)


if __name__ == "__main__":
    os.chdir(ROOT)
    main()
