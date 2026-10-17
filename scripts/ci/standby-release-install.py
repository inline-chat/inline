#!/usr/bin/env python3
"""Review-only until approved: fixed helper install, no keys/token/deploy/restart.

plan is local/read-only; install/verify must run through approved existing root
access on the exact role. Conflicts fail closed, successful repeats are no-ops.
"""
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile

ROOT = Path("/")
BUNDLE = Path(__file__).resolve().parent
TARGETS = {
    "nbg": {"ip": "91.107.255.57", "files": {
        "standby-release-host.py": "/usr/local/libexec/inline-standby-release",
        "standby-release-entrypoint.sh": "/usr/local/libexec/inline-standby-release-entrypoint"},
        "directories": ["/etc/inline-standby-release", "/var/lib/inline-standby-release"]},
    "controller": {"ip": "95.216.163.150", "files": {
        "standby-release-controller.py": "/usr/local/libexec/inline-standby-controller",
        "standby-release-controller-entrypoint.sh": "/usr/local/libexec/inline-standby-controller-entrypoint"},
        "directories": []}}


class Refused(Exception):
    pass


def need(value, code):
    if not value:
        raise Refused(code)


def rooted(path):
    return ROOT / path.lstrip("/")


def parents_safe(path):
    for parent in [path, *path.parents]:
        if parent.exists() or parent.is_symlink():
            metadata = parent.lstat()
            need(not stat.S_ISLNK(metadata.st_mode), "symlink_path")
            need(metadata.st_uid == 0 and not metadata.st_mode & 0o022, "unsafe_owner_or_mode")
        if parent == ROOT:
            break


def selected(role):
    need(role in TARGETS, "role")
    manifest = json.loads((BUNDLE / "standby-release-install.json").read_bytes())
    need(manifest.get("version") == 1 and set(manifest.get("roles", {})) == set(TARGETS), "manifest")
    items = manifest["roles"][role]
    need(len(items) == 2 and {x["source"]: x["destination"] for x in items} == TARGETS[role]["files"], "manifest_targets")
    out = []
    for item in items:
        source = BUNDLE / item["source"]
        need(source.is_file() and not source.is_symlink(), "bundle_file")
        data = source.read_bytes()
        need(item.get("mode") == 0o700 and hashlib.sha256(data).hexdigest() == item.get("sha256"), "bundle_hash")
        out.append((item, data))
    return out


def host_identity(role):
    need(os.geteuid() == 0, "root_required")
    result = subprocess.run(["ip", "-j", "address", "show"], capture_output=True, timeout=5)
    need(result.returncode == 0, "host_identity")
    addresses = {entry.get("local") for interface in json.loads(result.stdout) for entry in interface.get("addr_info", [])}
    need(TARGETS[role]["ip"] in addresses, "wrong_host")


def inspect(role):
    files = []
    for item, data in selected(role):
        path = rooted(item["destination"])
        parents_safe(path)
        exists = path.exists()
        if exists:
            metadata = path.lstat()
            need(stat.S_ISREG(metadata.st_mode) and stat.S_IMODE(metadata.st_mode) == 0o700
                 and path.read_bytes() == data, "existing_file_conflict")
        files.append({"path": item["destination"], "sha256": item["sha256"], "state": "matching" if exists else "absent"})
    for directory in TARGETS[role]["directories"]:
        path = rooted(directory)
        parents_safe(path)
        if path.exists():
            need(path.is_dir() and stat.S_IMODE(path.stat().st_mode) == 0o700, "existing_directory_conflict")
    return files


def directories(role):
    result = []
    for directory in TARGETS[role]["directories"]:
        path = rooted(directory)
        parents_safe(path)
        exists = path.exists()
        if exists:
            need(path.is_dir() and stat.S_IMODE(path.stat().st_mode) == 0o700, "existing_directory_conflict")
        result.append({"path": directory, "state": "matching" if exists else "absent"})
    return result


def sync_directory(path):
    descriptor = os.open(path, os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def install(role):
    files = inspect(role)  # Validate ALL inputs/conflicts before any file mutation.
    for directory in TARGETS[role]["directories"]:
        path = rooted(directory)
        existed = path.exists()
        path.mkdir(mode=0o700, parents=True, exist_ok=True)
        if not existed:
            sync_directory(path.parent)
    for item, data in selected(role):
        path = rooted(item["destination"])
        if path.exists():
            continue
        path.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
        descriptor, temporary = tempfile.mkstemp(prefix=".inline-standby-install-", dir=path.parent)
        try:
            with os.fdopen(descriptor, "wb") as output:
                os.fchmod(output.fileno(), 0o700)
                output.write(data)
                output.flush()
                os.fsync(output.fileno())
            # Do not overwrite a file created concurrently since preflight.
            os.link(temporary, path)
            sync_directory(path.parent)
        finally:
            os.unlink(temporary)
    return {"files": inspect(role), "directories": directories(role), "installedNewFiles": sum(x["state"] == "absent" for x in files),
            "keysChanged": False, "credentialsChanged": False, "servicesRestarted": False, "deploymentDispatched": False}


def main():
    need(len(sys.argv) == 3 and sys.argv[1] in ("plan", "install", "verify"), "arguments")
    action, role = sys.argv[1:]
    need(role in TARGETS, "role")
    if action == "plan":
        return {"ok": True, "action": action, "role": role,
                "files": [item for item, _ in selected(role)], "writes": False}
    host_identity(role)
    os.umask(0o077)
    if action == "install":
        result = install(role)
    else:
        result = {"files": inspect(role), "directories": directories(role)}
        need(all(x["state"] == "matching" for x in [*result["files"], *result["directories"]]), "installation_incomplete")
    return {"ok": True, "action": action, "role": role, **result}


if __name__ == "__main__":
    try:
        print(json.dumps(main()))
    except Exception as error:
        print(json.dumps({"ok": False, "code": str(error) if isinstance(error, Refused) else "private_install_failure"}))
        sys.exit(1)
