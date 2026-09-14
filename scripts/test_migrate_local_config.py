"""Fast migration safety tests. No real configuration or .env files are opened."""

import contextlib
import importlib.util
import io
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("migration", Path(__file__).with_name("migrate-local-config.py"))
migration = importlib.util.module_from_spec(spec)
spec.loader.exec_module(migration)


class MigrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.source = Path(self.temp.name) / "source"
        self.target = Path(self.temp.name) / "target"
        for root in (self.source, self.target):
            root.mkdir()
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            (root / ".gitignore").write_text("*.fixture\n")
        (self.source / "local.fixture").write_text("synthetic configuration\n")

    def run_migration(self, apply=False):
        with patch.object(migration, "candidates", return_value=["local.fixture"]), contextlib.redirect_stdout(io.StringIO()):
            return migration.migrate([(self.source, False)], self.target, apply)

    def test_dry_run_does_not_copy(self):
        self.assertEqual(self.run_migration(), 0)
        self.assertFalse((self.target / "local.fixture").exists())

    def test_copy_is_private_and_preserves_original(self):
        self.assertEqual(self.run_migration(True), 0)
        self.assertEqual((self.target / "local.fixture").read_text(), "synthetic configuration\n")
        self.assertEqual((self.target / "local.fixture").stat().st_mode & 0o777, 0o600)
        self.assertTrue((self.source / "local.fixture").exists())

    def test_existing_file_is_never_overwritten(self):
        (self.target / "local.fixture").write_text("keep me")
        self.run_migration(True)
        self.assertEqual((self.target / "local.fixture").read_text(), "keep me")
        with self.assertRaises(FileExistsError):
            migration.copy_new(self.source / "local.fixture", self.target / "local.fixture")

    def test_symlink_destination_is_not_followed(self):
        (self.target / "local.fixture").symlink_to(self.source / "local.fixture")
        self.run_migration(True)
        self.assertEqual((self.source / "local.fixture").read_text(), "synthetic configuration\n")

    def test_non_ignored_destination_is_rejected(self):
        (self.target / ".gitignore").write_text("")
        self.assertEqual(self.run_migration(True), 1)
        self.assertFalse((self.target / "local.fixture").exists())

    def test_tracked_destination_is_rejected_even_when_ignored(self):
        (self.target / "local.fixture").write_text("tracked")
        subprocess.run(["git", "-C", str(self.target), "add", "-f", "local.fixture"], check=True)
        self.assertFalse(migration.ignored_untracked(self.target, "local.fixture"))

    def test_parent_links_and_escapes_are_rejected(self):
        (self.target / "linked").symlink_to(self.source, target_is_directory=True)
        self.assertFalse(migration.safe_parent(self.target, "linked/local.fixture"))
        self.assertFalse(migration.safe_parent(self.target, "../local.fixture"))

    def test_mappings_only_inspect_path_strings(self):
        self.assertEqual(migration.mapped("apple/Local.xcconfig"), "apple/Local.xcconfig")
        self.assertEqual(migration.mapped("packages/url-preview/.env"), "server/packages/url-preview/.env")
        self.assertEqual(migration.mapped("hermes-agent/.env.local", True), "plugins/hermes-agent/.env.local")
        self.assertEqual(migration.mapped("sdk/.env", True), "packages/sdk/.env")
        self.assertIsNone(migration.mapped("web/.env"))


if __name__ == "__main__":
    unittest.main()
