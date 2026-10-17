#!/usr/bin/env python3
"""Fixed-resource forced SSH consumer. Installation/credentials are separate ops.

Wire format: one bounded JSON line, followed by exactly archiveBytes OCI tar bytes
for sync only. No caller command, path, host, token, config or env is accepted.
"""
import fcntl
import gzip
import hashlib
import http.client
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.parse

APP = "m1wmnjpqe0l2csuofcxsnzbf"
SERVER = "scpfllw5tavzzp2ezrufcwff"
REGISTRY = "127.0.0.1:5000/inline-api"
STATE = Path("/var/lib/inline-standby-release")
MAX_ARCHIVE = 768 * 1024 * 1024
MAX_ROOTFS = 2 * 1024**3
DIGEST = re.compile(r"sha256:[a-f0-9]{64}\Z")
SHA = re.compile(r"[a-f0-9]{40}\Z")
MEDIA = ("application/vnd.oci.image.manifest.v1+json", "application/vnd.docker.distribution.manifest.v2+json")


class Refused(Exception):
    pass


def need(condition, code):
    if not condition:
        raise Refused(code)


def encoded(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def validate_request(value, now=None):
    if value.get("action") == "probe":
        need(value == {"version": 1, "action": "probe"}, "probe_fields")
        return value
    fields = {"version", "action", "revision", "runtimeImage", "standbyImage", "runId", "attempt", "issuedAt"}
    if value.get("action") == "sync":
        fields |= {"archiveBytes", "archiveSha256"}
    need(set(value) == fields and value["version"] == 1, "request_fields")
    need(value["action"] in ("preflight", "sync", "check", "complete"), "request_action")
    need(isinstance(value["revision"], str) and SHA.fullmatch(value["revision"]), "request_revision")
    for key in ("runtimeImage", "standbyImage"):
        need(isinstance(value[key], str) and value[key].startswith("registry.fly.io/inline-api@")
             and DIGEST.fullmatch(value[key].split("@")[-1]), "request_image")
    need(value["runtimeImage"] != value["standbyImage"], "architecture_pair")
    for key in ("runId", "attempt"):
        need(type(value[key]) is int and 0 < value[key] < 10**16, "request_run")
    need(type(value["issuedAt"]) is int and -30 <= (now or time.time()) - value["issuedAt"] <= 900,
         "request_expired")
    if value["action"] == "sync":
        need(type(value["archiveBytes"]) is int and 0 < value["archiveBytes"] <= MAX_ARCHIVE, "archive_size")
        need(isinstance(value["archiveSha256"], str) and re.fullmatch(r"[a-f0-9]{64}", value["archiveSha256"]), "archive_hash")
    return value


def identity(request):
    return {key: request[key] for key in ("revision", "runtimeImage", "standbyImage", "runId", "attempt")}


def tag(request):
    return f"release-{request['revision']}-{request['runId']}-{request['attempt']}"


def env_fingerprint(env):
    # Stays in root-only local state, never emitted. Values never leave memory.
    stable = {k: v for k, v in env.items() if not k.startswith("COOLIFY_") and k not in ("SOURCE_COMMIT", "HOSTNAME")}
    return hashlib.sha256(encoded(stable)).hexdigest()


def verify_rootfs(archive, files, manifest, config):
    rootfs = config.get("rootfs", {})
    need(rootfs.get("type") == "layers" and isinstance(rootfs.get("diff_ids"), list)
         and len(rootfs["diff_ids"]) == len(manifest["layers"]), "rootfs_config")
    decoded_total, filesystem_total, entries = 0, 0, 0
    for layer, expected in zip(manifest["layers"], rootfs["diff_ids"]):
        need(isinstance(expected, str) and DIGEST.fullmatch(expected), "rootfs_digest")
        media = layer.get("mediaType", "")
        need(media in ("application/vnd.oci.image.layer.v1.tar+gzip", "application/vnd.docker.image.rootfs.diff.tar.gzip",
                       "application/vnd.oci.image.layer.v1.tar", "application/vnd.docker.image.rootfs.diff.tar"), "rootfs_compression")
        source = archive.extractfile(files["blobs/sha256/" + layer["digest"][7:]])
        decoded = gzip.GzipFile(fileobj=source) if media.endswith(("+gzip", ".gzip")) else source
        digest = hashlib.sha256()
        class BoundedReader:
            def read(self, size=-1):
                nonlocal decoded_total
                # Refuse giant PAX/sparse metadata allocation requests before read.
                need(0 <= size <= 2 * 1024 * 1024, "rootfs_metadata_size")
                data = decoded.read(size)
                decoded_total += len(data)
                need(decoded_total <= MAX_ROOTFS, "rootfs_decoded_limit")
                digest.update(data)
                return data
        reader = BoundedReader()
        with tarfile.open(fileobj=reader, mode="r|") as layer_tar:
            for member in layer_tar:
                entries += 1
                filesystem_total += member.size if member.isfile() else 0
                # Includes sparse files' declared logical size; compressed byte
                # and diff-ID checks alone cannot bound their disk allocation.
                need(entries <= 200000 and filesystem_total <= MAX_ROOTFS, "rootfs_filesystem_limit")
        while reader.read(1024 * 1024):
            pass
        need("sha256:" + digest.hexdigest() == expected, "rootfs_diff_id")
        decoded.close()
    return max(decoded_total, filesystem_total)


def validate_archive(path, request):
    """Verify tar in place, never extract caller paths. Hash every referenced blob."""
    with tarfile.open(path, "r:") as archive:
        members = archive.getmembers()
        need(len(members) < 2048, "archive_entries")
        files = {}
        for member in members:
            name = member.name.removeprefix("./")
            need(member.isfile() or member.isdir(), "archive_links")
            need(name in (".", "oci-layout", "index.json", "blobs", "blobs/sha256")
                 or re.fullmatch(r"blobs/sha256/[a-f0-9]{64}", name), "archive_path")
            if member.isfile():
                need(name not in files, "archive_duplicate")
                files[name] = member

        def read_json(name):
            need(name in files and files[name].size <= 2 * 1024 * 1024, "archive_metadata")
            return json.load(archive.extractfile(files[name]))

        need(read_json("oci-layout") == {"imageLayoutVersion": "1.0.0"}, "oci_layout")
        index = read_json("index.json")
        need(index.get("schemaVersion") == 2 and len(index.get("manifests", [])) == 1, "oci_index")
        descriptor = index["manifests"][0]
        digest = request["standbyImage"].split("@")[1]
        need(descriptor.get("digest") == digest and descriptor.get("mediaType") in MEDIA, "manifest_identity")
        manifest = read_json("blobs/sha256/" + digest[7:])
        need(manifest.get("schemaVersion") == 2 and manifest.get("mediaType") == descriptor["mediaType"], "manifest_type")
        need(isinstance(manifest.get("layers"), list) and 0 < len(manifest["layers"]) < 128, "manifest_layers")
        descriptors = [descriptor, manifest["config"], *manifest["layers"]]
        expected = {"oci-layout", "index.json"}
        for item in descriptors:
            blob = item.get("digest", "")
            need(DIGEST.fullmatch(blob) and type(item.get("size")) is int and item["size"] > 0, "blob_descriptor")
            name = "blobs/sha256/" + blob[7:]
            need(name in files and files[name].size == item["size"], "blob_size")
            expected.add(name)
            stream = archive.extractfile(files[name])
            h = hashlib.sha256()
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                h.update(chunk)
            need("sha256:" + h.hexdigest() == blob, "blob_hash")
        need(set(files) == expected, "archive_extra_blob")
        config = read_json("blobs/sha256/" + manifest["config"]["digest"][7:])
        need(config.get("architecture") == "arm64" and config.get("os") == "linux", "image_platform")
        need(config.get("config", {}).get("Labels", {}).get("org.opencontainers.image.revision") == request["revision"],
             "image_revision")
        return manifest, descriptors, verify_rootfs(archive, files, manifest, config)


def command(args, timeout=20, stdin=None):
    result = subprocess.run(args, input=stdin, capture_output=True, timeout=timeout, check=False)
    need(result.returncode == 0, "native_command")
    return result.stdout


class Host:
    def api(self, method, suffix, body=None):
        if method == "GET" and suffix == "/applications/" + APP:
            payload = {"version": 1, "operation": "read"}
        elif method == "PATCH" and suffix == "/applications/" + APP and set(body or {}) == {"docker_registry_image_tag"}:
            payload = {"version": 1, "operation": "select", "tag": body["docker_registry_image_tag"]}
        elif method == "POST" and suffix == "/applications/" + APP + "/start" and set(body or {}) == {"tag"}:
            payload = {"version": 1, "operation": "start", "tag": body["tag"]}
        else:
            raise Refused("controller_operation")
        # Only an app-scoped forced-command relay key lives on NBG. The existing
        # controller bearer stays on Finland; no bearer is copied to this host.
        data = command(["ssh", "-4", "-T", "-F", "/dev/null", "-o", "BatchMode=yes",
            "-o", "IdentitiesOnly=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=5",
            "-o", "LogLevel=ERROR", "-o", "UserKnownHostsFile=/etc/inline-standby-release/controller-known-hosts",
            "-i", "/etc/inline-standby-release/controller-key", "-p", "6642", "root@95.216.163.150",
            "inline-standby-controller-v1"], timeout=45, stdin=encoded(payload) + b"\n")
        need(len(data) <= 65536, "controller_response")
        value = json.loads(data)
        need(value.get("ok") is True and set(value) == {"ok", "app"}, "controller_response")
        return value["app"]

    def app(self):
        app = self.api("GET", "/applications/" + APP)
        server = app.get("server", {})
        settings = app.get("settings", {})
        need(app.get("uuid") == APP and server.get("uuid") == SERVER and server.get("ip") == "91.107.255.57",
             "resource_identity")
        need(app.get("build_pack") == "dockerimage" and app.get("fqdn") == "https://api.inline.chat"
             and app.get("docker_registry_image_name") == REGISTRY, "resource_intent")
        need(not app.get("ports_mappings") and settings.get("is_auto_deploy_enabled") is False
             and settings.get("is_preview_deployments_enabled") is False, "resource_automation")
        return app

    def runtime(self, request=None):
        ids = command(["docker", "ps", "--filter", "name=" + APP + "-", "--format", "{{.ID}} co"]).decode().splitlines()
        need(len(ids) == 1 and re.fullmatch(r"[a-f0-9]{12,64} co", ids[0]), "runtime_count")
        container = json.loads(command(["docker", "inspect", ids[0].split()[0]]))[0]
        image = json.loads(command(["docker", "image", "inspect", container["Image"]]))[0]
        name = container["Name"].lstrip("/")
        need(re.fullmatch(APP + r"-[0-9]+", name), "runtime_resource")
        need(container["State"].get("Running") is True and container["State"].get("Health", {}).get("Status") == "healthy"
             and not container["State"].get("OOMKilled"), "runtime_health")
        config = container["HostConfig"]
        need(not config.get("PortBindings") and config.get("Memory") == 1610612736
             and config.get("MemorySwap") == 1610612736 and config.get("NanoCpus") == 2000000000,
             "runtime_bounds")
        env = dict(item.split("=", 1) for item in container["Config"]["Env"] if "=" in item)
        expected = {"NODE_ENV": "production", "INLINE_PROCESS_ROLE": "all", "INLINE_REALTIME_DISTRIBUTED": "1",
                    "INLINE_DATABASE_QUERY_POOL_MAX": "3", "INLINE_INGRESS_MODE": "cloudflare-optional",
                    "INLINE_INGRESS_HOST": "api.inline.chat", "INLINE_INGRESS_DIRECT_IP_SOURCE": "x-real-ip",
                    "ENABLE_DATABASE_HEALTH_MONITOR": "0"}
        need(all(env.get(k) == v for k, v in expected.items()) and bool(env.get("REDIS_URL")), "runtime_intent")
        redis = urllib.parse.urlsplit(env["REDIS_URL"])
        need(redis.scheme == "redis" and redis.hostname == "172.18.0.1" and redis.port == 16379
             and bool(redis.password), "private_broker_endpoint")
        revision = image.get("Config", {}).get("Labels", {}).get("org.opencontainers.image.revision")
        need(image.get("Architecture") == "arm64" and image.get("Os") == "linux" and SHA.fullmatch(revision or ""), "runtime_image")
        if request:
            need(revision == request["revision"] and container["Config"]["Image"] == REGISTRY + ":" + tag(request)
                 and REGISTRY + "@" + request["standbyImage"].split("@")[1] in image.get("RepoDigests", []),
                 "runtime_release")
        return {"container": name, "imageId": container["Image"], "revision": revision,
                "environmentHash": env_fingerprint(env)}

    def ready(self):
        # Canonical hostname/SNI and public trust, forced to the local origin.
        data = command(["curl", "--silent", "--fail", "--noproxy", "*", "--max-time", "10", "--max-filesize", "65536",
                        "--resolve", "api.inline.chat:443:127.0.0.1", "https://api.inline.chat/readyz"], timeout=12)
        value = json.loads(data)
        need(value.get("status") == "ok" and all(value.get("checks", {}).get(key, {}).get("ok") is True
             for key in ("database", "clock", "broker")),
             "origin_readiness")

    def alternate(self):
        # Independent final guard after archive transfer/pull, immediately before
        # each controller mutation. Never probe the LB, which could return NBG.
        data = command(["curl", "--silent", "--fail", "--noproxy", "*", "--max-time", "5", "--max-filesize", "65536",
                        "--resolve", "api.inline.chat:443:66.241.124.189", "https://api.inline.chat/readyz"], timeout=7)
        value = json.loads(data)
        need(value.get("status") == "ok" and all(value.get("checks", {}).get(key, {}).get("ok") is True
             for key in ("database", "clock", "broker")), "alternate_origin_unready")

    def registry(self, method, path, body=None, headers=None, stream=None, size=0):
        connection = http.client.HTTPConnection("127.0.0.1", 5000, timeout=30)
        try:
            connection.putrequest(method, path)
            for key, value in (headers or {}).items():
                connection.putheader(key, value)
            connection.putheader("Content-Length", str(size if stream else len(body or b"")))
            connection.endheaders()
            if stream:
                while chunk := stream.read(1024 * 1024):
                    connection.send(chunk)
            elif body:
                connection.send(body)
            response = connection.getresponse()
            result = (response.status, dict(response.getheaders()), response.read(2 * 1024 * 1024 + 1))
            need(len(result[2]) <= 2 * 1024 * 1024, "registry_response")
            return result
        finally:
            connection.close()

    def mirror(self, path, request, manifest, descriptors):
        reference = tag(request)
        status, _, raw = self.registry("GET", "/v2/inline-api/manifests/" + reference,
                                       headers={"Accept": ",".join(MEDIA)})
        digest = request["standbyImage"].split("@")[1]
        if status == 200:
            need("sha256:" + hashlib.sha256(raw).hexdigest() == digest, "immutable_tag_conflict")
        else:
            need(status == 404, "registry_read")
            with tarfile.open(path, "r:") as archive:
                entries = {m.name.removeprefix("./"): m for m in archive.getmembers() if m.isfile()}
                for item in descriptors[1:]:
                    blob = item["digest"]
                    status, _, _ = self.registry("HEAD", "/v2/inline-api/blobs/" + blob)
                    if status == 200:
                        continue
                    need(status == 404, "registry_blob_read")
                    status, headers, _ = self.registry("POST", "/v2/inline-api/blobs/uploads/")
                    need(status == 202, "registry_blob_start")
                    location = headers.get("Location", headers.get("location", ""))
                    parsed = urllib.parse.urlsplit(location)
                    need(parsed.scheme in ("", "http") and parsed.netloc in ("", "127.0.0.1:5000")
                         and parsed.path.startswith("/v2/inline-api/blobs/uploads/"), "registry_location")
                    query = parsed.query + ("&" if parsed.query else "") + urllib.parse.urlencode({"digest": blob})
                    member = entries["blobs/sha256/" + blob[7:]]
                    status, _, _ = self.registry("PUT", parsed.path + "?" + query,
                         headers={"Content-Type": "application/octet-stream"}, stream=archive.extractfile(member), size=member.size)
                    need(status == 201, "registry_blob_write")
                member = entries["blobs/sha256/" + digest[7:]]
                status, _, _ = self.registry("PUT", "/v2/inline-api/manifests/" + reference,
                       body=archive.extractfile(member).read(), headers={"Content-Type": manifest["mediaType"]})
                need(status == 201, "registry_manifest_write")
        status, _, raw = self.registry("GET", "/v2/inline-api/manifests/" + reference, headers={"Accept": ",".join(MEDIA)})
        need(status == 200 and "sha256:" + hashlib.sha256(raw).hexdigest() == digest, "registry_readback")
        command(["docker", "pull", REGISTRY + "@" + digest], timeout=120)

    def headroom(self, rootfs_bytes=0, archive_bytes=0):
        fields = dict(line.split(":", 1) for line in Path("/proc/meminfo").read_text().splitlines())
        need(int(fields["MemAvailable"].split()[0]) * 1024 >= 2 * 1024**3, "memory_headroom")
        # The incoming archive is already on disk. Reserve registry blobs, Docker
        # compressed cache, the full decoded filesystem, and 1 GiB untouched.
        required = max(3 * 1024**3, 2 * archive_bytes + rootfs_bytes + 1024**3)
        need(shutil.disk_usage(STATE).free >= required and shutil.disk_usage("/var/lib/docker").free >= required,
             "disk_headroom")


def save(path, value):
    temporary = path.with_suffix(".tmp")
    with temporary.open("wb") as stream:
        stream.write(encoded(value))
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)
    fd = os.open(path.parent, os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def probe(host):
    app = host.app()
    current = host.runtime()
    host.ready()
    host.alternate()
    host.headroom()
    return {"version": 1, "ok": True, "action": "probe", "resource": APP, "server": SERVER,
            "checkedAt": int(time.time()), "container": current["container"], "revision": current["revision"],
            "configuredTag": app["docker_registry_image_tag"], "directTlsReady": True,
            "alternateTlsReady": True, "headroomReady": True, "releaseQualified": False,
            "journalChanged": False, "deploymentDispatched": False}


def perform(request, host, journal, write, archive=None):
    selected = identity(request)
    action = request["action"]
    same = journal is not None and journal["release"] == selected
    if action == "preflight":
        if journal and not same:
            need(journal["phase"] == "complete" and
                 (request["runId"], request["attempt"]) > (journal["release"]["runId"], journal["release"]["attempt"]),
                 "previous_release_unresolved_or_newer")
        if same:
            need(journal["phase"] == "prepared", "preflight_already_consumed")
        app = host.app()
        current = host.runtime()
        host.ready()
        if same:
            need(current == journal["before"] and app["docker_registry_image_tag"] == journal["previousTag"], "predecessor_changed")
        else:
            journal = {"phase": "prepared", "release": selected, "before": current,
                       "previousTag": app["docker_registry_image_tag"], "preparedAt": int(time.time())}
            write(journal)
    elif action == "sync":
        need(same, "preflight_missing")
        if journal["phase"] in ("verified", "complete"):
            current = host.runtime(request)
            host.ready()
            need(host.app()["docker_registry_image_tag"] == tag(request) and current == journal["after"]
                 and current["environmentHash"] == journal["before"]["environmentHash"], "runtime_changed")
        elif journal["phase"] == "dispatching":
            # A late successful deploy may close a previous timeout, but an old,
            # failed or partial deployment never authorizes another start request.
            need(host.app()["docker_registry_image_tag"] == tag(request), "dispatch_requires_reconciliation")
            current = host.runtime(request)
            need(current["environmentHash"] == journal["before"]["environmentHash"], "runtime_environment_changed")
            host.ready()
            journal.update(phase="verified", after=current, verifiedAt=int(time.time()))
            write(journal)
        else:
            need(journal["phase"] == "prepared" and time.time() - journal["preparedAt"] <= 1800, "sync_requires_reconciliation")
            app = host.app()
            need(host.runtime() == journal["before"] and app["docker_registry_image_tag"] == journal["previousTag"], "predecessor_changed")
            host.ready()
            host.headroom()
            manifest, descriptors, rootfs_bytes = validate_archive(archive, request)
            host.headroom(rootfs_bytes, request["archiveBytes"])
            host.mirror(archive, request, manifest, descriptors)
            host.alternate()
            journal.update(phase="patching", archiveSha256=request["archiveSha256"])
            write(journal)  # Intent is durable BEFORE the first controller mutation.
            host.api("PATCH", "/applications/" + APP, {"docker_registry_image_tag": tag(request)})
            need(host.app()["docker_registry_image_tag"] == tag(request), "patch_readback")
            host.alternate()
            journal["phase"] = "dispatching"
            write(journal)
            # A timeout or malformed response is ambiguous. Observe once, never redispatch.
            try:
                host.api("POST", "/applications/" + APP + "/start", {"tag": tag(request)})
            except Exception:
                pass
            deadline = time.monotonic() + 300
            current = None
            while time.monotonic() < deadline:
                try:
                    candidate = host.runtime(request)
                    need(candidate["environmentHash"] == journal["before"]["environmentHash"], "runtime_environment_changed")
                    host.ready()
                    current = candidate
                    break
                except Exception:
                    time.sleep(5)
            need(current is not None, "dispatch_unresolved")
            journal.update(phase="verified", after=current, verifiedAt=int(time.time()))
            write(journal)
    else:
        need(same and journal["phase"] in ("verified", "complete"), "release_not_verified")
        need(host.app()["docker_registry_image_tag"] == tag(request), "resource_tag_changed")
        current = host.runtime(request)
        need(current == journal["after"] and current["environmentHash"] == journal["before"]["environmentHash"], "runtime_changed")
        host.ready()
        if action == "complete":
            journal.update(phase="complete", completedAt=int(time.time()))
            write(journal)
    # Deliberate safe projection: never return controller payloads or environment hashes.
    return {"version": 1, "ok": True, "action": action, "resource": APP, "server": SERVER,
            "release": selected, "phase": journal["phase"], "checkedAt": int(time.time()),
            "container": journal.get("after", journal["before"])["container"], "directTlsReady": True}


def main():
    need(os.geteuid() == 0 and sys.argv[1:] == ["--execute"] and
         os.environ.get("SSH_ORIGINAL_COMMAND") == "inline-standby-release-v1" and not os.environ.get("SSH_TTY"), "entrypoint")
    os.umask(0o077)
    signal.signal(signal.SIGALRM, lambda *_: (_ for _ in ()).throw(Refused("deadline")))
    signal.alarm(780)
    line = sys.stdin.buffer.readline(16385)
    need(len(line) <= 16384 and line.endswith(b"\n"), "request_line")
    request = validate_request(json.loads(line))
    if request["action"] == "probe":
        need(sys.stdin.buffer.read(1) == b"", "unexpected_payload")
        return probe(Host())
    STATE.mkdir(mode=0o700, parents=True, exist_ok=True)
    with (STATE / "lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise Refused("release_busy")
        path = STATE / "journal.json"
        journal = json.loads(path.read_bytes()) if path.exists() else None
        with tempfile.TemporaryDirectory(prefix="incoming-", dir=STATE) as directory:
            archive = Path(directory) / "image.tar"
            if request["action"] == "sync":
                Host().headroom()
                remaining = request["archiveBytes"]
                h = hashlib.sha256()
                with archive.open("wb") as output:
                    while remaining:
                        data = sys.stdin.buffer.read(min(1024 * 1024, remaining))
                        need(bool(data), "archive_truncated")
                        h.update(data)
                        output.write(data)
                        remaining -= len(data)
                need(sys.stdin.buffer.read(1) == b"" and h.hexdigest() == request["archiveSha256"], "archive_transport")
            else:
                need(sys.stdin.buffer.read(1) == b"", "unexpected_payload")
            return perform(request, Host(), journal, lambda value: save(path, value), archive)


if __name__ == "__main__":
    try:
        print(json.dumps(main()))
    except Exception as error:
        # No exception text from providers, subprocesses, credentials or JSON bodies.
        code = str(error) if isinstance(error, Refused) else "private_operation_failed"
        print(json.dumps({"version": 1, "ok": False, "code": code, "reconcileBeforeRetry": True}))
        sys.exit(1)
