#!/usr/bin/env python3
"""Manual main-release runner transport; no provider mutations outside forced SSH."""
import hashlib
import importlib.util
import json
import os
import signal
import resource
from pathlib import Path
import subprocess
import sys
import tempfile
import time

spec = importlib.util.spec_from_file_location("standby_host", Path(__file__).with_name("standby-release-host.py"))
host = importlib.util.module_from_spec(spec)
spec.loader.exec_module(host)


def request(action, archive=None):
    host.need(os.environ.get("GITHUB_EVENT_NAME") == "workflow_dispatch" and
              os.environ.get("GITHUB_REPOSITORY") == "inline-chat/inline" and
              os.environ.get("GITHUB_REF") == "refs/heads/main" and
              os.environ.get("STANDBY_SYNC_ENABLED") == "true", "release_not_enabled")
    value = {"version": 1, "action": action, "revision": os.environ["GITHUB_SHA"],
             "runtimeImage": os.environ["RUNTIME_IMAGE"], "standbyImage": os.environ["STANDBY_IMAGE"],
             "runId": int(os.environ["GITHUB_RUN_ID"]), "attempt": int(os.environ["GITHUB_RUN_ATTEMPT"]),
             "issuedAt": int(time.time())}
    if action == "sync":
        path = Path(archive)
        h = hashlib.sha256()
        with path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                h.update(chunk)
        value.update(archiveBytes=path.stat().st_size, archiveSha256=h.hexdigest())
        host.validate_archive(path, host.validate_request(value))
    return host.validate_request(value)


def validate_receipt(value, selected, now=None):
    host.need(set(value) == {"version", "ok", "action", "resource", "server", "release", "phase",
                             "checkedAt", "container", "directTlsReady"}, "receipt_fields")
    phase = {"preflight": "prepared", "sync": "verified", "check": "verified", "complete": "complete"}[selected["action"]]
    # A completed exact run can be safely checked/re-read without dispatching again.
    phases = (phase, "complete") if selected["action"] in ("sync", "check") else (phase,)
    host.need(value["version"] == 1 and value["ok"] is True and value["action"] == selected["action"]
              and value["resource"] == host.APP and value["server"] == host.SERVER
              and value["release"] == host.identity(selected) and value["phase"] in phases
              and value["directTlsReady"] is True, "receipt_identity")
    host.need(type(value["checkedAt"]) is int and -5 <= (now or time.time()) - value["checkedAt"] <= 60,
              "receipt_stale")
    host.need(isinstance(value["container"], str) and host.re.fullmatch(host.APP + r"-[0-9]+", value["container"]),
              "receipt_container")


def main():
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    signal.signal(signal.SIGALRM, lambda *_: (_ for _ in ()).throw(host.Refused("client_deadline")))
    signal.alarm(840)
    host.need(len(sys.argv) in (3, 4), "arguments")
    action, destination = sys.argv[1:3]
    archive = sys.argv[3] if len(sys.argv) == 4 else None
    host.need((action == "sync") == (archive is not None), "archive_arguments")
    selected = request(action, archive)
    # Never persist bearer credentials. This key authorizes only the fixed host
    # consumer and exists solely on the ephemeral protected production runner.
    with tempfile.TemporaryDirectory(prefix="standby-ssh-", dir=os.environ["RUNNER_TEMP"]) as folder:
        os.chmod(folder, 0o700)
        key = Path(folder) / "key"
        key.write_text(os.environ["STANDBY_RELEASE_SSH_KEY"] + "\n")
        key.chmod(0o600)
        known = Path(folder) / "known_hosts"
        known.write_text(os.environ["STANDBY_RELEASE_KNOWN_HOSTS"] + "\n")
        known.chmod(0o600)
        # Do not inherit provider credentials into the SSH process.
        environment = {"PATH": os.environ["PATH"], "HOME": folder, "LANG": "C.UTF-8"}
        with tempfile.TemporaryFile() as stdout, tempfile.TemporaryFile() as stderr:
            process = subprocess.Popen(["ssh", "-T", "-F", "/dev/null", "-o", "BatchMode=yes",
                "-o", "IdentitiesOnly=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=10",
                "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2", "-o", "LogLevel=ERROR",
                "-o", "UserKnownHostsFile=" + str(known), "-i", str(key), "root@91.107.255.57",
                "inline-standby-release-v1"], env=environment, stdin=subprocess.PIPE, stdout=stdout, stderr=stderr)
            try:
                process.stdin.write(host.encoded(selected) + b"\n")
                if archive:
                    with open(archive, "rb") as stream:
                        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                            process.stdin.write(chunk)
                process.stdin.close()
                process.wait(timeout=810)
                host.need(process.returncode == 0, "remote_operation_failed_reconcile")
                stdout.seek(0)
                data = stdout.read(16385)
                host.need(len(data) <= 16384, "receipt_size")
                receipt = json.loads(data)
                validate_receipt(receipt, selected)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=10)
    # A second vantage checks the actual NBG TLS origin, never the canonical LB.
    result = subprocess.run(["curl", "--silent", "--fail", "--noproxy", "*", "--max-time", "15", "--max-filesize", "65536",
        "--resolve", "api.inline.chat:443:91.107.255.57", "https://api.inline.chat/readyz"],
        capture_output=True, timeout=20)
    host.need(result.returncode == 0, "independent_origin_tls")
    value = json.loads(result.stdout)
    host.need(value.get("status") == "ok" and all(value.get("checks", {}).get(key, {}).get("ok") is True
        for key in ("database", "clock", "broker")), "independent_origin_readiness")
    Path(destination).write_bytes(host.encoded(receipt) + b"\n")
    print(json.dumps({"ok": True, "action": action, "runId": selected["runId"], "revision": selected["revision"]}))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        code = str(error) if isinstance(error, host.Refused) else "private_operation_failed"
        print(json.dumps({"ok": False, "code": code, "reconcileBeforeRetry": True}))
        sys.exit(1)
