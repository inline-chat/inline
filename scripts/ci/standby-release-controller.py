#!/usr/bin/env python3
"""Existing Finland controller only: app-scoped SSH facade, bearer never leaves.

Install only after root reviews the existing token's scope/provenance. A narrow
facade does not make a broad bearer safe to move onto another origin host.
"""
import json
import os
from pathlib import Path
import re
import signal
import sys
import urllib.request

APP = "m1wmnjpqe0l2csuofcxsnzbf"
SERVER = "scpfllw5tavzzp2ezrufcwff"
ORIGIN = "https://supermanage.inline.chat/api/v1"
TAG = re.compile(r"release-[a-f0-9]{40}-[1-9][0-9]{0,15}-[1-9][0-9]{0,15}\Z")


class Refused(Exception):
    pass


def need(value, code):
    if not value:
        raise Refused(code)


def validate(value):
    need(value.get("version") == 1 and value.get("operation") in ("read", "select", "start"), "request")
    fields = {"version", "operation"} if value["operation"] == "read" else {"version", "operation", "tag"}
    need(set(value) == fields, "fields")
    if "tag" in fields:
        need(isinstance(value["tag"], str) and TAG.fullmatch(value["tag"]), "tag")
    return value


def project(app):
    settings = app.get("settings", {})
    # Actual Docker-image application GET schema: server belongs to destination.
    server = app.get("destination", {}).get("server", {})
    need(app.get("uuid") == APP and server.get("uuid") == SERVER and server.get("ip") == "91.107.255.57"
         and app.get("build_pack") == "dockerimage" and app.get("fqdn") == "https://api.inline.chat"
         and app.get("docker_registry_image_name") == "127.0.0.1:5000/inline-api" and not app.get("ports_mappings")
         and settings.get("is_auto_deploy_enabled") is False and settings.get("is_preview_deployments_enabled") is False,
         "resource_identity_or_intent")
    return {"uuid": APP, "server": {"uuid": SERVER, "ip": server["ip"]},
            **{k: app.get(k) for k in ("build_pack", "fqdn", "docker_registry_image_name", "docker_registry_image_tag", "ports_mappings")},
            "settings": {k: settings[k] for k in ("is_auto_deploy_enabled", "is_preview_deployments_enabled")}}


class Controller:
    def __init__(self, token):
        self.token = token

    def api(self, method, suffix, body=None):
        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, *args, **kwargs):
                return None
        request = urllib.request.Request(ORIGIN + suffix, method=method,
            data=None if body is None else json.dumps(body).encode(),
            headers={"Authorization": "Bearer " + self.token, "Content-Type": "application/json", "User-Agent": "coolify-cli"})
        with urllib.request.build_opener(NoRedirect).open(request, timeout=15) as response:
            data = response.read(2 * 1024 * 1024 + 1)
            need(len(data) <= 2 * 1024 * 1024, "provider_size")
            return json.loads(data)


def perform(value, controller):
    value = validate(value)
    path = "/applications/" + APP
    before = project(controller.api("GET", path))
    if value["operation"] == "select":
        if before["docker_registry_image_tag"] != value["tag"]:
            controller.api("PATCH", path, {"docker_registry_image_tag": value["tag"]})
        before = project(controller.api("GET", path))
        need(before["docker_registry_image_tag"] == value["tag"], "select_readback")
    elif value["operation"] == "start":
        need(before["docker_registry_image_tag"] == value["tag"], "start_tag_changed")
        controller.api("POST", path + "/start")
    return {"ok": True, "app": before}


def main():
    need(os.geteuid() == 0 and sys.argv[1:] == ["--execute"] and
         os.environ.get("SSH_ORIGINAL_COMMAND") == "inline-standby-controller-v1" and not os.environ.get("SSH_TTY"), "entrypoint")
    signal.signal(signal.SIGALRM, lambda *_: (_ for _ in ()).throw(Refused("deadline")))
    signal.alarm(65)
    line = sys.stdin.buffer.readline(4097)
    need(len(line) <= 4096 and line.endswith(b"\n") and sys.stdin.buffer.read(1) == b"", "input")
    value = validate(json.loads(line))
    directory = os.environ.get("CREDENTIALS_DIRECTORY", "")
    need(directory.startswith("/run/credentials/"), "credential_namespace")
    token = (Path(directory) / "coolify").read_text().strip()
    need(bool(token) and "\n" not in token, "credential_format")
    return perform(value, Controller(token))


if __name__ == "__main__":
    try:
        print(json.dumps(main()))
    except Exception as error:
        code = str(error) if isinstance(error, Refused) else "private_operation_failed"
        print(json.dumps({"ok": False, "code": code}))
        sys.exit(1)
