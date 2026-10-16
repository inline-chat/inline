#!/usr/bin/env python3
"""Synthetic-only acceptance: no Docker, providers, SSH, credentials or env files."""
import copy
import hashlib
import gzip
import importlib.util
import io
import json
import sys
from pathlib import Path
import tarfile
import tempfile
import time
import unittest
from unittest.mock import patch


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


host = module("standby_host_tests", "standby-release-host.py")
client = module("standby_client_tests", "standby-release-client.py")
controller = module("standby_controller_tests", "standby-release-controller.py")
REVISION = "1" * 40


def request(action="preflight"):
    return {"version": 1, "action": action, "revision": REVISION,
            "runtimeImage": "registry.fly.io/inline-api@sha256:" + "2" * 64,
            "standbyImage": "registry.fly.io/inline-api@sha256:" + "3" * 64,
            "runId": 100, "attempt": 1, "issuedAt": int(time.time())}


def image_archive(directory, config=None, extra=None, change_layer=False):
    value = request("sync")
    config = config or {"architecture": "arm64", "os": "linux", "config": {
        "Labels": {"org.opencontainers.image.revision": REVISION}}}
    layer_buffer = io.BytesIO()
    with tarfile.open(fileobj=layer_buffer, mode="w:") as layer_tar:
        item = tarfile.TarInfo("synthetic.txt")
        item.size = 17
        layer_tar.addfile(item, io.BytesIO(b"synthetic content"))
    layer_tar_bytes = layer_buffer.getvalue()
    config.setdefault("rootfs", {"type": "layers", "diff_ids": ["sha256:" + hashlib.sha256(layer_tar_bytes).hexdigest()]})
    config_data = host.encoded(config)
    layer_data = gzip.compress(layer_tar_bytes, mtime=0)
    def descriptor(data, media):
        return {"mediaType": media, "size": len(data), "digest": "sha256:" + hashlib.sha256(data).hexdigest()}
    conf = descriptor(config_data, "application/vnd.oci.image.config.v1+json")
    layer = descriptor(layer_data, "application/vnd.oci.image.layer.v1.tar+gzip")
    manifest_data = host.encoded({"schemaVersion": 2, "mediaType": host.MEDIA[0], "config": conf, "layers": [layer]})
    manifest = descriptor(manifest_data, host.MEDIA[0])
    entries = {"oci-layout": host.encoded({"imageLayoutVersion": "1.0.0"}),
               "index.json": host.encoded({"schemaVersion": 2, "manifests": [manifest]}),
               "blobs/sha256/" + manifest["digest"][7:]: manifest_data,
               "blobs/sha256/" + conf["digest"][7:]: config_data,
               "blobs/sha256/" + layer["digest"][7:]: layer_data if not change_layer else b"x" * len(layer_data)}
    entries.update(extra or {})
    path = Path(directory) / "image.tar"
    with tarfile.open(path, "w:") as archive:
        for name, data in entries.items():
            info = tarfile.TarInfo(name)
            info.size = len(data)
            archive.addfile(info, io.BytesIO(data))
    value.update(standbyImage="registry.fly.io/inline-api@" + manifest["digest"], archiveBytes=path.stat().st_size,
                 archiveSha256=hashlib.sha256(path.read_bytes()).hexdigest())
    return path, value


class FakeHost:
    def __init__(self):
        self.tag = "previous-retained-release"
        self.current = {"container": host.APP + "-123", "imageId": "old", "revision": "0" * 40,
                        "environmentHash": "secret-fingerprint-not-for-output"}
        self.events = []
        self.desired = None
        self.dispatch_timeout = False
        self.patch_timeout = False
        self.replace_error = False
        self.unhealthy = False
        self.no_headroom = False
        self.alternate_unhealthy = False

    def app(self):
        return {"docker_registry_image_tag": self.tag}

    def runtime(self, value=None):
        if value:
            host.need(self.current["revision"] == value["revision"], "runtime_release")
        return copy.deepcopy(self.current)

    def ready(self):
        host.need(not self.unhealthy, "origin_readiness")

    def headroom(self, *args):
        host.need(not self.no_headroom, "memory_headroom")

    def alternate(self):
        host.need(not self.alternate_unhealthy, "alternate_origin_unready")

    def mirror(self, path, value, manifest, descriptors):
        self.events.append("mirror")
        self.desired = value

    def api(self, method, suffix, body=None):
        if method == "PATCH":
            self.events.append("patch")
            self.tag = body["docker_registry_image_tag"]
            if self.patch_timeout:
                raise TimeoutError("private-provider-body-token")
        else:
            assert method == "POST" and suffix == "/applications/" + host.APP + "/start"
            self.events.append("dispatch")
            if not self.replace_error:
                self.current.update(container=host.APP + "-456", imageId="new", revision=self.desired["revision"])
            if self.dispatch_timeout:
                raise TimeoutError("private-provider-body-token")
        return {}


class TransactionTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path, self.value = image_archive(self.directory.name)
        self.runtime = FakeHost()
        self.journal = None

    def write(self, value):
        self.journal = copy.deepcopy(value)
        self.runtime.events.append("journal:" + value["phase"])

    def run_action(self, action):
        value = dict(self.value, action=action)
        if action != "sync":
            del value["archiveBytes"], value["archiveSha256"]
        return host.perform(value, self.runtime, self.journal, self.write, self.path)

    def test_normal_release_preserves_environment_and_binds_both_digests(self):
        self.run_action("preflight")
        receipt = self.run_action("sync")
        self.assertEqual(self.runtime.events, ["journal:prepared", "mirror", "journal:patching", "patch",
                                               "journal:dispatching", "dispatch", "journal:verified"])
        self.assertEqual(receipt["release"], host.identity(self.value))
        self.assertNotIn("secret-fingerprint", json.dumps(receipt))
        self.assertEqual(self.run_action("check")["phase"], "verified")
        self.assertEqual(self.run_action("complete")["phase"], "complete")

    def test_dispatch_timeout_reconciles_without_duplicate_request(self):
        self.runtime.dispatch_timeout = True
        self.run_action("preflight")
        self.run_action("sync")
        self.run_action("sync")
        self.assertEqual(self.runtime.events.count("dispatch"), 1)

    def test_uncertain_patch_cannot_be_repeated(self):
        self.runtime.patch_timeout = True
        self.run_action("preflight")
        with self.assertRaises(TimeoutError):
            self.run_action("sync")
        self.assertEqual(self.journal["phase"], "patching")
        with self.assertRaises(host.Refused):
            self.run_action("sync")
        self.assertEqual(self.runtime.events.count("patch"), 1)
        self.assertNotIn("dispatch", self.runtime.events)

    def test_failed_dispatch_remains_fenced_and_does_not_rollback(self):
        self.run_action("preflight")
        self.runtime.replace_error = True
        with patch.object(host.time, "monotonic", side_effect=[0, 301]):
            with self.assertRaisesRegex(host.Refused, "dispatch_unresolved"):
                self.run_action("sync")
        with self.assertRaises(host.Refused):
            self.run_action("sync")
        self.assertEqual(self.runtime.events.count("dispatch"), 1)
        self.assertEqual(self.journal["phase"], "dispatching")
        self.assertEqual(self.runtime.current["imageId"], "old")

    def test_late_successful_dispatch_can_close_without_redispatch(self):
        self.run_action("preflight")
        self.runtime.replace_error = True
        with patch.object(host.time, "monotonic", side_effect=[0, 301]):
            with self.assertRaises(host.Refused):
                self.run_action("sync")
        self.runtime.current.update(container=host.APP + "-456", imageId="new", revision=self.value["revision"])
        self.assertEqual(self.run_action("sync")["phase"], "verified")
        self.assertEqual(self.runtime.events.count("dispatch"), 1)

    def test_missing_or_changed_predecessor_refused_before_mutation(self):
        with self.assertRaisesRegex(host.Refused, "preflight_missing"):
            self.run_action("sync")
        self.run_action("preflight")
        self.runtime.current["imageId"] = "other"
        with self.assertRaisesRegex(host.Refused, "predecessor_changed"):
            self.run_action("sync")
        self.assertNotIn("mirror", self.runtime.events)

    def test_unhealthy_or_no_headroom_refused_before_update(self):
        self.run_action("preflight")
        for field in ("unhealthy", "no_headroom"):
            setattr(self.runtime, field, True)
            with self.assertRaises(host.Refused):
                self.run_action("sync")
            setattr(self.runtime, field, False)
        self.assertNotIn("patch", self.runtime.events)

    def test_fly_loss_after_archive_mirror_stops_before_app_mutation(self):
        self.run_action("preflight")
        self.runtime.alternate_unhealthy = True
        with self.assertRaisesRegex(host.Refused, "alternate_origin_unready"):
            self.run_action("sync")
        self.assertIn("mirror", self.runtime.events)
        self.assertNotIn("patch", self.runtime.events)
        self.assertNotIn("dispatch", self.runtime.events)

    def test_stale_or_overlapping_release_cannot_overwrite_newer(self):
        self.run_action("preflight")
        for phase in ("prepared", "patching", "dispatching", "verified", "complete"):
            self.journal["phase"] = phase
            for run in (99, 101):
                value = dict(self.value, action="preflight", runId=run)
                allowed = phase == "complete" and run == 101
                if allowed:
                    result = host.perform(value, self.runtime, self.journal, lambda _: None)
                    self.assertEqual(result["phase"], "prepared")
                else:
                    with self.assertRaisesRegex(host.Refused, "previous_release_unresolved_or_newer"):
                        host.perform(value, self.runtime, self.journal, lambda _: None)

    def test_runtime_change_after_sync_blocks_fly_gate(self):
        self.run_action("preflight")
        self.run_action("sync")
        self.runtime.current["environmentHash"] = "different"
        with self.assertRaisesRegex(host.Refused, "runtime_changed"):
            self.run_action("check")

    def test_preserves_root_only_atomic_journal(self):
        path = Path(self.directory.name) / "journal.json"
        with patch.object(host.os, "O_DIRECTORY", getattr(host.os, "O_DIRECTORY", 0)):
            host.save(path, {"phase": "dispatching"})
        self.assertEqual(json.loads(path.read_bytes()), {"phase": "dispatching"})
        self.assertFalse(path.with_suffix(".tmp").exists())


class ArtifactTests(unittest.TestCase):
    def test_exact_archive_passes_without_docker(self):
        with tempfile.TemporaryDirectory() as directory:
            path, value = image_archive(directory)
            manifest, descriptors, rootfs_bytes = host.validate_archive(path, value)
            self.assertEqual(manifest["config"], descriptors[1])

    def test_corrupt_layer_wrong_platform_and_wrong_revision_rejected(self):
        for config, corrupt, code in [
            (None, True, "blob_hash"),
            ({"architecture": "amd64", "os": "linux"}, False, "image_platform"),
            ({"architecture": "arm64", "os": "linux", "config": {"Labels": {"org.opencontainers.image.revision": "a" * 40}}}, False, "image_revision"),
        ]:
            with self.subTest(code=code), tempfile.TemporaryDirectory() as directory:
                path, value = image_archive(directory, config, change_layer=corrupt)
                with self.assertRaisesRegex(host.Refused, code):
                    host.validate_archive(path, value)

    def test_decoded_filesystem_and_diff_id_limits_precede_any_registry_write(self):
        with tempfile.TemporaryDirectory() as directory:
            path, value = image_archive(directory)
            with patch.object(host, "MAX_ROOTFS", 10), self.assertRaisesRegex(host.Refused, "rootfs_(decoded|filesystem)_limit"):
                host.validate_archive(path, value)
        with tempfile.TemporaryDirectory() as directory:
            config = {"architecture": "arm64", "os": "linux", "config": {"Labels": {"org.opencontainers.image.revision": REVISION}},
                      "rootfs": {"type": "layers", "diff_ids": ["sha256:" + "0" * 64]}}
            path, value = image_archive(directory, config)
            with self.assertRaisesRegex(host.Refused, "rootfs_diff_id"):
                host.validate_archive(path, value)

    def test_extra_blob_and_path_traversal_are_not_extracted_or_imported(self):
        for name, code in [("../../escape", "archive_path"), ("blobs/sha256/" + "f" * 64, "archive_extra_blob")]:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                path, value = image_archive(directory, extra={name: b"bad"})
                with self.assertRaisesRegex(host.Refused, code):
                    host.validate_archive(path, value)

    def test_request_rejects_stale_replay_wrong_registry_extra_command_and_oversize(self):
        value = request()
        for change in [{"issuedAt": value["issuedAt"] - 901}, {"issuedAt": value["issuedAt"] + 31},
                       {"standbyImage": "elsewhere.example/a@sha256:" + "3" * 64},
                       {"command": "shell"}, {"revision": "main"}, {"runId": True},
                       {"runtimeImage": value["standbyImage"]}]:
            with self.subTest(change=change), self.assertRaises(host.Refused):
                host.validate_request(dict(value, **change), now=value["issuedAt"])
        with tempfile.TemporaryDirectory() as directory:
            _, value = image_archive(directory)
            with self.assertRaisesRegex(host.Refused, "archive_size"):
                host.validate_request(dict(value, archiveBytes=host.MAX_ARCHIVE + 1))

    def test_existing_conflicting_registry_tag_is_never_replaced(self):
        with tempfile.TemporaryDirectory() as directory:
            path, value = image_archive(directory)
            manifest, descriptors, rootfs_bytes = host.validate_archive(path, value)
            instance = host.Host()
            with patch.object(instance, "registry", return_value=(200, {}, b"foreign manifest")) as registry:
                with self.assertRaisesRegex(host.Refused, "immutable_tag_conflict"):
                    instance.mirror(path, value, manifest, descriptors)
                registry.assert_called_once()

    def test_original_blob_and_manifest_bytes_mirror_then_exact_digest_pull(self):
        with tempfile.TemporaryDirectory() as directory:
            path, value = image_archive(directory)
            manifest, descriptors, rootfs_bytes = host.validate_archive(path, value)
            instance = host.Host()
            blobs, manifests = {}, {}
            def registry(method, route, body=None, headers=None, stream=None, size=0):
                if method == "GET":
                    return (200, {}, manifests[route]) if route in manifests else (404, {}, b"")
                if method == "HEAD":
                    return (200 if route.split("/")[-1] in blobs else 404, {}, b"")
                if method == "POST":
                    return 202, {"Location": "http://127.0.0.1:5000/v2/inline-api/blobs/uploads/synthetic"}, b""
                if stream:
                    data = stream.read()
                    digest = host.urllib.parse.parse_qs(host.urllib.parse.urlsplit(route).query)["digest"][0]
                    self.assertEqual("sha256:" + hashlib.sha256(data).hexdigest(), digest)
                    self.assertEqual(len(data), size)
                    blobs[digest] = data
                    return 201, {}, b""
                manifests[route] = body
                return 201, {}, b""
            with patch.object(instance, "registry", side_effect=registry), patch.object(host, "command") as command:
                instance.mirror(path, value, manifest, descriptors)
                command.assert_called_once_with(["docker", "pull", host.REGISTRY + "@" + value["standbyImage"].split("@")[1]], timeout=120)
            self.assertEqual(len(blobs), 2)
            self.assertEqual("sha256:" + hashlib.sha256(next(iter(manifests.values()))).hexdigest(), value["standbyImage"].split("@")[1])

    def test_receipt_identity_freshness_and_safe_projection(self):
        selected = request("check")
        receipt = {"version": 1, "ok": True, "action": "check", "resource": host.APP, "server": host.SERVER,
                   "release": host.identity(selected), "phase": "verified", "checkedAt": selected["issuedAt"],
                   "container": host.APP + "-456", "directTlsReady": True}
        client.validate_receipt(receipt, selected, now=selected["issuedAt"])
        for change in [{"checkedAt": selected["issuedAt"] - 61}, {"server": "other"}, {"phase": "prepared"},
                       {"release": dict(receipt["release"], attempt=2)}, {"rawProviderBody": "private"}]:
            with self.subTest(change=change), self.assertRaises(client.host.Refused):
                client.validate_receipt(dict(receipt, **change), selected, now=selected["issuedAt"])


class NativeProjectionTests(unittest.TestCase):
    def fixture(self):
        value = request()
        env = {"NODE_ENV": "production", "INLINE_PROCESS_ROLE": "all", "INLINE_REALTIME_DISTRIBUTED": "1",
               "INLINE_DATABASE_QUERY_POOL_MAX": "3", "INLINE_INGRESS_MODE": "cloudflare-optional",
               "INLINE_INGRESS_HOST": "api.inline.chat", "INLINE_INGRESS_DIRECT_IP_SOURCE": "x-real-ip",
               "ENABLE_DATABASE_HEALTH_MONITOR": "0", "REDIS_URL": "redis://fixture:synthetic-private@172.18.0.1:16379",
               "SYNTHETIC_SECRET": "never-output"}
        container = {"Name": "/" + host.APP + "-456", "Image": "exact-image-id",
                     "State": {"Running": True, "Health": {"Status": "healthy"}, "OOMKilled": False},
                     "Config": {"Env": [k + "=" + v for k, v in env.items()], "Image": host.REGISTRY + ":" + host.tag(value)},
                     "HostConfig": {"Memory": 1610612736, "MemorySwap": 1610612736,
                                    "NanoCpus": 2000000000, "PortBindings": {}}}
        image = {"Architecture": "arm64", "Os": "linux", "Config": {"Labels": {"org.opencontainers.image.revision": value["revision"]}},
                 "RepoDigests": [host.REGISTRY + "@" + value["standbyImage"].split("@")[1]]}
        return value, container, image

    def inspect(self, value, container, image):
        with patch.object(host, "command", side_effect=[b"aabbccddeeff co\n", host.encoded([container]), host.encoded([image])]):
            return host.Host().runtime(value)

    def test_native_identity_and_configuration_are_verified_not_app_git_metadata(self):
        value, container, image = self.fixture()
        projected = self.inspect(value, container, image)
        self.assertEqual(projected["revision"], value["revision"])
        self.assertNotIn("never-output", json.dumps(projected))
        for mutate in [lambda c, i: i.update(RepoDigests=[]), lambda c, i: i.update(Architecture="amd64"),
                       lambda c, i: c["HostConfig"].update(PortBindings={"8000/tcp": [{}]}),
                       lambda c, i: c["State"]["Health"].update(Status="starting"),
                       lambda c, i: c["Config"].update(Env=[e for e in c["Config"]["Env"] if not e.startswith("REDIS_URL=")]),
                       lambda c, i: c["Config"].update(Env=[e.replace("INLINE_PROCESS_ROLE=all", "INLINE_PROCESS_ROLE=api") for e in c["Config"]["Env"]])]:
            c, i = copy.deepcopy(container), copy.deepcopy(image)
            mutate(c, i)
            with self.assertRaises(host.Refused):
                self.inspect(value, c, i)

    def test_broker_degradation_does_not_pass_ordinary_release(self):
        good = {"status": "ok", "checks": {k: {"ok": True} for k in ("database", "clock", "broker")}}
        with patch.object(host, "command", return_value=host.encoded(good)):
            host.Host().ready()

        good["checks"]["broker"]["ok"] = False
        with patch.object(host, "command", return_value=host.encoded(good)), self.assertRaisesRegex(host.Refused, "origin_readiness"):
            host.Host().ready()


class ControllerBoundaryTests(unittest.TestCase):
    def test_nbg_relay_rejects_other_resources_and_never_loads_controller_token(self):
        with patch.object(host, "command", return_value=host.encoded({"ok": True, "app": {"uuid": host.APP}})) as command:
            host.Host().api("GET", "/applications/" + host.APP)
            args, kwargs = command.call_args
            self.assertIn("inline-standby-controller-v1", args[0])
            self.assertIn("root@95.216.163.150", args[0])
            self.assertEqual(json.loads(kwargs["stdin"]), {"version": 1, "operation": "read"})
        with patch.object(host, "command") as command, self.assertRaisesRegex(host.Refused, "controller_operation"):
            host.Host().api("PATCH", "/applications/other", {"docker_registry_image_tag": "latest"})
        command.assert_not_called()

    def fixture(self):
        return {"uuid": controller.APP, "server": {"uuid": controller.SERVER, "ip": "91.107.255.57"},
                "build_pack": "dockerimage", "fqdn": "https://api.inline.chat", "ports_mappings": None,
                "docker_registry_image_name": "127.0.0.1:5000/inline-api", "docker_registry_image_tag": "previous",
                "settings": {"is_auto_deploy_enabled": False, "is_preview_deployments_enabled": False},
                "env": "private-provider-payload"}

    def test_fixed_resource_only_and_no_provider_or_credential_payload_leaks(self):
        app = self.fixture()
        api = unittest.mock.Mock()
        api.api.return_value = app
        result = controller.perform({"version": 1, "operation": "read"}, api)
        self.assertNotIn("private-provider-payload", json.dumps(result))
        api.api.assert_called_once_with("GET", "/applications/" + controller.APP)
        for value in [{"version": 1, "operation": "read", "target": "other"},
                      {"version": 1, "operation": "select", "tag": "latest"},
                      {"version": 1, "operation": "shell"}]:
            with self.assertRaises(controller.Refused):
                controller.perform(value, api)
        app["uuid"] = "another-app"
        with self.assertRaises(controller.Refused):
            controller.perform({"version": 1, "operation": "start", "tag": host.tag(request())}, api)

    def test_select_is_tag_only_idempotent_and_start_requires_exact_tag(self):
        app = self.fixture()
        events = []
        class API:
            def api(self, method, path, body=None):
                events.append((method, path, body))
                if method == "PATCH":
                    self_tag = body["docker_registry_image_tag"]
                    app["docker_registry_image_tag"] = self_tag
                return app
        desired = host.tag(request())
        with self.assertRaisesRegex(controller.Refused, "start_tag_changed"):
            controller.perform({"version": 1, "operation": "start", "tag": desired}, API())
        controller.perform({"version": 1, "operation": "select", "tag": desired}, API())
        controller.perform({"version": 1, "operation": "select", "tag": desired}, API())
        controller.perform({"version": 1, "operation": "start", "tag": desired}, API())
        mutations = [event for event in events if event[0] != "GET"]
        self.assertEqual(mutations, [("PATCH", "/applications/" + controller.APP, {"docker_registry_image_tag": desired}),
                                     ("POST", "/applications/" + controller.APP + "/start", None)])

    def test_request_requires_manual_main_same_repository_and_explicit_activation(self):
        good = {"GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_REPOSITORY": "inline-chat/inline",
                "GITHUB_REF": "refs/heads/main", "STANDBY_SYNC_ENABLED": "true", "GITHUB_SHA": REVISION,
                "RUNTIME_IMAGE": request()["runtimeImage"], "STANDBY_IMAGE": request()["standbyImage"],
                "GITHUB_RUN_ID": "100", "GITHUB_RUN_ATTEMPT": "1"}
        with patch.dict(client.os.environ, good, clear=True):
            client.request("preflight")
        for key, wrong in [("GITHUB_EVENT_NAME", "push"), ("GITHUB_REPOSITORY", "outsider/inline"),
                           ("GITHUB_REF", "refs/heads/other"), ("STANDBY_SYNC_ENABLED", "")]:
            with patch.dict(client.os.environ, dict(good, **{key: wrong}), clear=True), self.assertRaisesRegex(client.host.Refused, "release_not_enabled"):
                client.request("preflight")


if __name__ == "__main__":
    if len(sys.argv) == 5 and sys.argv[1] == "--oci-archive":
        path, revision, digest = Path(sys.argv[2]), sys.argv[3], sys.argv[4]
        with path.open("rb") as stream:
            archive_hash = hashlib.file_digest(stream, "sha256").hexdigest()
        value = dict(request("sync"), revision=revision, standbyImage="registry.fly.io/inline-api@" + digest,
                     archiveBytes=path.stat().st_size, archiveSha256=archive_hash)
        host.validate_request(value)
        _, _, rootfs_bytes = host.validate_archive(path, value)
        print(json.dumps({"ok": True, "revision": revision, "manifestDigest": digest, "rootfsBytes": rootfs_bytes}))
    else:
        unittest.main()
