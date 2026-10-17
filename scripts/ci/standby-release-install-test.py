import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("installer", Path(__file__).with_name("standby-release-install.py"))
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.guard = patch.object(installer, "ROOT", self.root)
        self.guard.start()
        self.addCleanup(self.guard.stop)
        # Fixtures test safe path logic without requiring local root ownership.
        self.owner = patch.object(installer, "parents_safe")
        self.owner.start()
        self.addCleanup(self.owner.stop)

    def test_exact_install_is_idempotent_and_leaves_no_keys_tokens_or_services(self):
        first = installer.install("nbg")
        self.assertEqual(first["installedNewFiles"], 2)
        second = installer.install("nbg")
        self.assertEqual(second["installedNewFiles"], 0)
        self.assertFalse(first["keysChanged"] or first["credentialsChanged"] or first["servicesRestarted"])
        self.assertEqual(len(list(self.root.rglob("inline-standby-release"))), 3)
        self.assertTrue(all(x["state"] == "matching" for x in second["files"]))

    def test_conflict_rejected_before_any_partial_install(self):
        path = installer.rooted("/usr/local/libexec/inline-standby-controller-entrypoint")
        path.parent.mkdir(parents=True)
        path.write_bytes(b"foreign")
        path.chmod(0o700)
        with self.assertRaisesRegex(installer.Refused, "existing_file_conflict"):
            installer.install("controller")
        self.assertFalse(path.with_name("inline-standby-controller").exists())
        self.assertEqual(path.read_bytes(), b"foreign")

    def test_verify_rejects_missing_dedicated_directory(self):
        installer.install("nbg")
        installer.rooted("/etc/inline-standby-release").rmdir()
        with patch.object(installer, "host_identity"), patch.object(installer.sys, "argv", ["installer", "verify", "nbg"]), \
             self.assertRaisesRegex(installer.Refused, "installation_incomplete"):
            installer.main()
        self.assertIn({"path": "/etc/inline-standby-release", "state": "absent"}, installer.directories("nbg"))

    def test_hash_tampering_rejected_and_no_output_files_created(self):
        manifest = json.loads((installer.BUNDLE / "standby-release-install.json").read_bytes())
        manifest["roles"]["nbg"][0]["sha256"] = "0" * 64
        original = Path.read_bytes
        def read(path):
            return json.dumps(manifest).encode() if path == installer.BUNDLE / "standby-release-install.json" else original(path)
        with patch.object(Path, "read_bytes", read), self.assertRaisesRegex(installer.Refused, "bundle_hash"):
            installer.install("nbg")
        self.assertEqual(list(self.root.iterdir()), [])

    def test_symlink_path_rejected_by_real_guard(self):
        self.owner.stop()
        # root ownership is checked after the symlink itself, so this portable
        # fixture reaches the symlink refusal without a real root fixture.
        link = self.root / "link"
        link.symlink_to(self.root / "foreign")
        with self.assertRaisesRegex(installer.Refused, "symlink_path"):
            installer.parents_safe(link)
        self.owner.start()


if __name__ == "__main__":
    unittest.main()
