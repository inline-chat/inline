#!/usr/bin/env python3
"""Exercise the public installer with real archives and isolated Linux fixtures."""
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class InstallerTest(unittest.TestCase):
    def install(self, shell, architecture, libc, *, bad_checksum=False, jq=False):
        with tempfile.TemporaryDirectory(prefix="inline-installer-") as directory:
            root = Path(directory)
            tools = root / "tools"
            tools.mkdir()
            # Deliberately omit jq by default to exercise minimal Linux images.
            for name in ["mktemp", "tar", "install", "shasum", "sha256sum", "curl", "dirname",
                         "mkdir", "cat", "tr", "sed", "head", "grep", "rm", "mv"] + (["jq"] if jq else []):
                executable = shutil.which(name)
                if executable:
                    (tools / name).symlink_to(executable)
            (tools / "uname").write_text(
                '#!/bin/sh\ncase "$1" in -s) echo Linux;; -m) echo ' + architecture + ';; esac\n'
            )
            # musl ldd commonly returns nonzero for --version.
            (tools / "ldd").write_text(
                '#!/bin/sh\necho "' + libc + ' libc" >&2\nexit ' + ('1' if libc == 'musl' else '0') + '\n'
            )
            for name in ["uname", "ldd"]:
                (tools / name).chmod(0o755)
            payload = b'#!/bin/sh\necho "inline fixture"\n'
            archive = root / "inline.tar.gz"
            with tarfile.open(archive, "w:gz") as tar:
                info = tarfile.TarInfo("inline")
                info.size = len(payload)
                info.mode = 0o755
                tar.addfile(info, io.BytesIO(payload))
            target = f"{architecture}-unknown-linux-{libc}"
            digest = hashlib.sha256(archive.read_bytes()).hexdigest()
            manifest = root / "manifest.json"
            manifest.write_text(json.dumps({"version": "1.2.3", "targets": {target: {
                "url": archive.as_uri(), "sha256": '0' * 64 if bad_checksum else digest,
            }}}))
            # Neither .local nor bin exists yet, as on a fresh server account.
            destination = root / "home" / ".local" / "bin"
            (root / "home").mkdir()
            result = subprocess.run([shell], input=(ROOT / "cli/install.sh").read_text(),
                text=True, capture_output=True, timeout=20, env={
                    "PATH": str(tools), "HOME": str(root / "home"),
                    "INLINE_INSTALL_DIR": str(destination),
                    "INLINE_RELEASE_MANIFEST_URL": manifest.as_uri(),
                    "TMPDIR": str(root),
                })
            if bad_checksum:
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((destination / "inline").exists())
            else:
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(f"Detected target: {target}", result.stderr)
                self.assertEqual((destination / "inline").read_bytes(), payload)
                self.assertTrue(os.access(destination / "inline", os.X_OK))

    def test_linux_architectures_libcs_and_shells(self):
        for shell in dict.fromkeys(filter(None, [shutil.which("sh"), shutil.which("dash"), shutil.which("bash")])):
            for architecture in ["x86_64", "aarch64"]:
                for libc in ["gnu", "musl"]:
                    with self.subTest(shell=shell, architecture=architecture, libc=libc):
                        self.install(shell, architecture, libc)

    def test_checksum_mismatch_never_installs(self):
        self.install(shutil.which("sh"), "x86_64", "gnu", bad_checksum=True)

    @unittest.skipUnless(shutil.which("jq"), "jq not installed")
    def test_jq_manifest_parser(self):
        self.install(shutil.which("sh"), "aarch64", "gnu", jq=True)


if __name__ == "__main__":
    unittest.main()
