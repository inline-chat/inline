#!/usr/bin/env python3
"""Exercise the public installer with real archives and isolated Linux fixtures."""
import base64
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class InstallerTest(unittest.TestCase):
    def install(self, shell, architecture, libc, *, bad_checksum=False, jq=False, signed=False, bad_signature=False, wrong_channel=False, unsafe_archive=False, preserve_existing=False, preserve_symlink=False):
        with tempfile.TemporaryDirectory(prefix="inline-installer-") as directory:
            root = Path(directory)
            tools = root / "tools"
            tools.mkdir()
            # Deliberately omit jq by default to exercise minimal Linux images.
            for name in ["mktemp", "tar", "gzip", "install", "shasum", "sha256sum", "curl", "dirname",
                         "mkdir", "cat", "tr", "sed", "head", "grep", "rm", "mv", "wc", "openssl", "chmod", "sleep"] + (["jq"] if jq else []):
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
            payload = b'#!/bin/sh\necho "inline 1.2.3"\n'
            archive = root / "inline.tar.gz"
            with tarfile.open(archive, "w:gz") as tar:
                info = tarfile.TarInfo("inline")
                info.size = len(payload)
                info.mode = 0o755
                if unsafe_archive:
                    info.type = tarfile.SYMTYPE
                    info.linkname = "outside"
                    info.size = 0
                    tar.addfile(info)
                else:
                    tar.addfile(info, io.BytesIO(payload))
            target = f"{architecture}-unknown-linux-{libc}"
            digest = hashlib.sha256(archive.read_bytes()).hexdigest()
            manifest = root / "manifest.json"
            manifest.write_text(json.dumps({"version": "1.2.3", "targets": {target: {
                "url": archive.as_uri(), "sha256": '0' * 64 if bad_checksum else digest, "size": archive.stat().st_size,
            }}}))
            # Neither .local nor bin exists yet, as on a fresh server account.
            destination = root / "home" / ".local" / "bin"
            (root / "home").mkdir()
            script = (ROOT / "cli/install.sh").read_text()
            environment = {
                "PATH": str(tools), "HOME": str(root / "home"),
                "INLINE_INSTALL_DIR": str(destination),
                "INLINE_RELEASE_MANIFEST_URL": manifest.as_uri(), "TMPDIR": str(root),
            }
            if signed:
                candidates = [shutil.which("openssl"), "/opt/homebrew/opt/openssl@3/bin/openssl", "/usr/local/opt/openssl@3/bin/openssl"]
                key = root / "rfc8032-public-test-seed.der"
                key.write_bytes(bytes.fromhex("302e020100300506032b6570042204209d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"))
                key.chmod(0o600)
                crypto = next((c for c in candidates if c and Path(c).exists() and subprocess.run([c, "pkey", "-inform", "DER", "-in", str(key), "-noout"], capture_output=True).returncode == 0), None)
                if not crypto: self.skipTest("OpenSSL Ed25519 support unavailable")
                (tools / "openssl").unlink()
                (tools / "openssl").symlink_to(crypto)
                public = subprocess.check_output([crypto, "pkey", "-inform", "DER", "-in", str(key), "-pubout", "-outform", "DER"])
                script = script.replace("MCowBQYDK2VwAyEAXRnthgyciTxQh/hF6QgvPjCy0CorCD4IlW4Nwlknoyo=", base64.b64encode(public).decode())
                release = json.loads(manifest.read_text())
                release.update(formatVersion=1, channel="alpha" if wrong_channel else "stable", generation=100)
                release["targets"][target]["url"] = "https://fixture.invalid/archive.tar.gz"
                payload_bytes = json.dumps(release, separators=(",", ":")).encode()
                message = root / "signed-bytes"
                message.write_bytes(b"inline-cli-channel-v1\0" + payload_bytes)
                signature_file = root / "signature"
                subprocess.run([crypto, "pkeyutl", "-sign", "-rawin", "-inkey", str(key), "-keyform", "DER", "-in", str(message), "-out", str(signature_file)], check=True, capture_output=True)
                signature = bytearray(signature_file.read_bytes())
                if bad_signature: signature[0] ^= 1
                manifest.write_text(json.dumps({"payload": base64.b64encode(payload_bytes).decode(), "signatures": [{"keyId": "inline-cli-2026-10", "signature": base64.b64encode(signature).decode()}]}, separators=(",", ":")))
                (tools / "curl").unlink()
                (tools / "curl").write_text(f"#!{sys.executable}\nimport sys, shutil\nfrom pathlib import Path\nargs=sys.argv[1:]\nurl=next(x for x in args if x.startswith('https://'))\nsource={str(manifest)!r} if '.json' in url else {str(archive)!r}\nshutil.copyfile(source,args[args.index('-o')+1])\n")
                (tools / "curl").chmod(0o755)
                environment.pop("INLINE_RELEASE_MANIFEST_URL")
            if preserve_existing:
                existing = tools / "inline"
                existing.write_text("foreign installation must survive")
                existing.chmod(0o755)
                environment.pop("INLINE_INSTALL_DIR")
            if preserve_symlink:
                destination.mkdir(parents=True)
                original = root / "package-owned"
                original.write_text("package manager owns this")
                (destination / "inline").symlink_to(original)
            result = subprocess.run([shell], input=script,
                text=True, capture_output=True, timeout=20, env=environment)
            if preserve_existing:
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(existing.read_text(), "foreign installation must survive")
                self.assertFalse((destination / "inline").exists())
            elif preserve_symlink:
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue((destination / "inline").is_symlink())
                self.assertEqual(original.read_text(), "package manager owns this")
            elif bad_checksum or bad_signature or wrong_channel or unsafe_archive:
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

    def test_signed_bootstrap_verifies_payload_and_never_falls_back_after_tampering(self):
        for options in [{}, {"bad_signature": True}, {"wrong_channel": True}]:
            with self.subTest(options=options):
                self.install(shutil.which("sh"), "x86_64", "gnu", signed=True, **options)

    def test_preserves_foreign_installations_symlinks_and_archive_paths(self):
        for options in [{"preserve_existing": True}, {"preserve_symlink": True}, {"unsafe_archive": True}]:
            with self.subTest(options=options):
                self.install(shutil.which("sh"), "x86_64", "gnu", **options)

    def test_checksum_mismatch_never_installs(self):
        self.install(shutil.which("sh"), "x86_64", "gnu", bad_checksum=True)

    @unittest.skipUnless(shutil.which("jq"), "jq not installed")
    def test_jq_manifest_parser(self):
        self.install(shutil.which("sh"), "aarch64", "gnu", jq=True)


if __name__ == "__main__":
    unittest.main()
