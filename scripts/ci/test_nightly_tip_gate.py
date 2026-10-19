import importlib.util
import hashlib
import io
import re
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("nightly_tip_gate", Path(__file__).with_name("nightly-tip-gate.py"))
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


SHA = "a" * 40
OTHER_SHA = "b" * 40
NEWER_SHA = "d" * 40
NEWEST_SHA = "e" * 40
DIGEST = "c" * 64
NOW = datetime(2026, 10, 19, 12, 0, tzinfo=timezone.utc)


def feed_xml(*, signature="signed", version="100", description="Build 100 from commit aaaaaaa.",
             pub_date="Mon, 19 Oct 2026 09:00:00 +0000"):
    return f'''<?xml version="1.0"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
<description>&lt;p&gt;{description}&lt;/p&gt;</description>
<pubDate>{pub_date}</pubDate>
<sparkle:version>{version}</sparkle:version>
<sparkle:shortVersionString>1.0</sparkle:shortVersionString>
<sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
<sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
<enclosure url="https://public-assets.inline.chat/mac/tip/100/Inline.dmg" length="123"
 sparkle:edSignature="{signature}" />
</item></channel></rss>'''.encode()


def run(workflow_id, *, sha=SHA, status="completed", conclusion="success", event="push"):
    return {"id": workflow_id, "head_sha": sha, "head_branch": "main", "event": event,
            "status": status, "conclusion": conclusion}


class FakeGitHub:
    def __init__(self):
        self.runs = {name: [run(10)] for name in gate.REQUIRED_WORKFLOWS}
        self.runs.update({name: [] for name in gate.OPTIONAL_PUSH_WORKFLOWS})
        self.codeql = [{"id": 1, "name": "Analyze (actions)", "app": {"slug": "github-actions"},
                        "status": "completed", "conclusion": "success"}]

    def request(self, path):
        if path == "git/ref/heads/main":
            return {"object": {"sha": SHA}}
        workflow = path.split("/runs?", 1)[0].rsplit("/", 1)[-1]
        return {"workflow_runs": self.runs[workflow]}

    def checks(self, sha):
        self.assert_sha = sha
        return self.codeql


class FakeMain:
    """Recent main history, newest first, with per-commit workflow runs."""

    def __init__(self, commits, tip=SHA, comparison=None):
        self.commits = commits
        self.tip = tip
        self.comparison = comparison or {"status": "ahead", "files": [{"filename": "apple/InlineMac/App.swift"}]}
        self.runs = {name: [] for name in (*gate.REQUIRED_WORKFLOWS, *gate.OPTIONAL_PUSH_WORKFLOWS)}
        for index, (sha, state) in enumerate(reversed(commits)):
            for name in gate.REQUIRED_WORKFLOWS:
                status, conclusion = ("in_progress", None) if state == "running" else ("completed", state)
                self.runs[name].append(run(index + 1, sha=sha, status=status, conclusion=conclusion))

    def tip_commit(self):
        return self.tip

    def main_push_runs(self, workflow):
        return self.runs[workflow]

    def main_commits(self):
        return [{"sha": sha} for sha, _ in self.commits]

    def compare(self, base, head):
        return self.comparison

    def checks(self, sha):
        return FakeGitHub().codeql

    def request(self, path, missing_ok=False):
        raise AssertionError(f"unexpected request {path}")


class NightlyTipGateTests(unittest.TestCase):
    def test_only_exact_current_main_with_green_runs_and_codeql_is_selected(self):
        github = FakeGitHub()
        self.assertEqual(gate.inspect_main(github), (SHA, None))
        github.runs["integrations.yml"] = [run(9), run(10, sha=OTHER_SHA)]
        self.assertEqual(gate.inspect_main(github), (SHA, None))
        github.runs["integrations.yml"].append(run(11, status="in_progress", conclusion=None))
        self.assertIn("in_progress", gate.inspect_main(github)[1])
        github.runs["integrations.yml"][-1] = run(11, conclusion="failure")
        self.assertIn("failure", gate.inspect_main(github)[1])
        github.runs["integrations.yml"][-1] = run(11)
        github.codeql[0]["conclusion"] = "failure"
        self.assertIn("CodeQL", gate.inspect_main(github)[1])

    def test_missing_required_run_fails_closed(self):
        github = FakeGitHub()
        github.runs["apple-validation.yml"] = [run(1, sha=OTHER_SHA)]
        self.assertIn("missing", gate.inspect_main(github)[1])

    def test_triggered_cli_build_must_be_green(self):
        github = FakeGitHub()
        github.runs["cli-check.yml"] = [run(12, conclusion="failure")]
        self.assertIn("cli-check.yml", gate.inspect_main(github)[1])
        github.runs["cli-check.yml"] = [run(12)]
        self.assertEqual(gate.inspect_main(github), (SHA, None))

    def test_skip_requires_matching_tag_release_asset_and_latest_feed(self):
        feed = gate.latest_feed_item(feed_xml())
        release = {"assets": [{"name": "Inline.dmg", "size": 123, "digest": f"sha256:{DIGEST}"}]}
        self.assertTrue(gate.published_tip_matches(SHA, SHA, release, feed, DIGEST))
        self.assertFalse(gate.published_tip_matches(SHA, OTHER_SHA, release, feed, DIGEST))
        self.assertFalse(gate.published_tip_matches(SHA, SHA, {"assets": []}, feed, DIGEST))
        self.assertFalse(gate.published_tip_matches(SHA, SHA, release, {**feed, "dmg_size": 124}, DIGEST))
        self.assertFalse(gate.published_tip_matches(SHA, SHA, release, {**feed, "commit_prefix": "bbbbbbb"}, DIGEST))
        self.assertFalse(gate.published_tip_matches(SHA, SHA, release, feed, "d" * 64))
        self.assertFalse(gate.published_tip_matches(SHA, SHA, release, feed, None))

    def test_invalid_appcast_cannot_masquerade_as_first_publication(self):
        with self.assertRaises(ValueError):
            gate.latest_feed_item(b"<rss><channel /></rss>")
        with self.assertRaises(ValueError):
            gate.latest_feed_item(b"<rss><channel><item /></channel></rss>")
        with self.assertRaises(ValueError):
            gate.latest_feed_item(feed_xml(signature=""))
        with self.assertRaises(ValueError):
            gate.latest_feed_item(feed_xml(version="101"))
        experimental = gate.latest_feed_item(feed_xml(description="Experimental tip build 100."))
        self.assertIsNone(experimental["commit_prefix"])
        self.assertFalse(gate.published_tip_matches(SHA, SHA, {"assets": []}, experimental, DIGEST))

    def test_remote_dmg_hash_requires_exact_signed_length(self):
        feed = gate.latest_feed_item(feed_xml())
        with patch.object(gate.urllib.request, "urlopen", return_value=io.BytesIO(b"a" * 123)):
            self.assertEqual(gate.remote_dmg_sha256(feed), hashlib.sha256(b"a" * 123).hexdigest())
        with patch.object(gate.urllib.request, "urlopen", return_value=io.BytesIO(b"a" * 122)):
            with self.assertRaisesRegex(ValueError, "length differs"):
                gate.remote_dmg_sha256(feed)


class TipCadenceTests(unittest.TestCase):
    def test_only_known_non_mac_paths_skip_a_build(self):
        self.assertFalse(gate.mac_relevant(["server/src/index.ts", "landing/src/start.ts", "README.md"]))
        self.assertTrue(gate.mac_relevant(["server/src/index.ts", "apple/InlineMac/App.swift"]))
        self.assertTrue(gate.mac_relevant(["packages/protocol/src/roots.ts"]))
        self.assertTrue(gate.mac_relevant([".github/workflows/macos-tip-nightly.yml"]))
        self.assertTrue(gate.mac_relevant(None))
        self.assertFalse(gate.mac_relevant([]))

    def test_non_mac_paths_match_apple_validation_policy(self):
        source = (Path(__file__).with_name("validation-gates.mjs")).read_text()
        pattern = re.search(r"const unrelated = /(.+)/\n", source).group(1)
        self.assertEqual(gate.NON_MAC_PATHS.pattern, pattern.replace("\\/", "/"))

    def test_changed_paths_include_renames_and_fail_open_when_truncated(self):
        comparison = {"files": [{"filename": "server/a.ts", "previous_filename": "apple/a.swift"}]}
        self.assertEqual(gate.changed_paths(comparison), ["server/a.ts", "apple/a.swift"])
        self.assertIsNone(gate.changed_paths({"files": [{"filename": "server/a.ts"}] * gate.COMPARE_FILE_LIMIT}))
        self.assertIsNone(gate.changed_paths({}))

    def test_tip_decision_enforces_paths_and_interval_except_manual_runs(self):
        server_only = {"status": "ahead", "files": [{"filename": "server/a.ts"}]}
        mac = {"status": "ahead", "files": [{"filename": "apple/a.swift"}]}
        recent = {"published_at": NOW - timedelta(minutes=30)}
        old = {"published_at": NOW - timedelta(minutes=61)}
        self.assertIn("older", gate.tip_decision({"status": "behind"}, old, event="workflow_dispatch", now=NOW))
        self.assertIn("macOS-relevant", gate.tip_decision(server_only, old, event="workflow_run", now=NOW))
        self.assertIn("macOS-relevant", gate.tip_decision(server_only, old, event="schedule", now=NOW))
        self.assertIsNone(gate.tip_decision(server_only, old, event="workflow_dispatch", now=NOW))
        self.assertIsNone(gate.tip_decision({"status": "diverged", "files": []}, old, event="workflow_run", now=NOW))
        self.assertIn("published", gate.tip_decision(mac, recent, event="workflow_run", now=NOW))
        self.assertIsNone(gate.tip_decision(mac, recent, event="workflow_dispatch", now=NOW))
        self.assertIsNone(gate.tip_decision(mac, old, event="workflow_run", now=NOW))
        self.assertIsNone(gate.tip_decision(None, None, event="workflow_run", now=NOW))

    def test_feed_publication_time_is_parsed(self):
        item = gate.latest_feed_item(feed_xml())
        self.assertEqual(item["published_at"], datetime(2026, 10, 19, 9, 0, tzinfo=timezone.utc))
        self.assertIsNone(gate.latest_feed_item(feed_xml(pub_date=""))["published_at"])

    def test_newest_green_commit_is_selected_and_newer_ci_is_reported(self):
        main = FakeMain([(NEWEST_SHA, "running"), (NEWER_SHA, "success"), (OTHER_SHA, "failure"), (SHA, "success")])
        self.assertEqual(gate.newest_green_main(main, SHA), (NEWER_SHA, NEWEST_SHA))
        main = FakeMain([(NEWER_SHA, "cancelled"), (OTHER_SHA, "failure"), (SHA, "success")])
        self.assertEqual(gate.newest_green_main(main, SHA), (SHA, None))
        main = FakeMain([(NEWER_SHA, "failure"), (SHA, "failure"), (OTHER_SHA, "success")])
        self.assertEqual(gate.newest_green_main(main, SHA), (None, None))

    def test_ci_triggers_wait_for_newer_commits_but_the_sweep_does_not(self):
        main = FakeMain([(NEWER_SHA, "running"), (OTHER_SHA, "success"), (SHA, "success")])
        feed = {"published_at": NOW - timedelta(hours=2)}
        with patch.object(gate, "public_feed", return_value=feed):
            sha, problem, _ = gate.select_tip(main, "workflow_run", NOW)
            self.assertEqual(sha, OTHER_SHA)
            self.assertIn("still in CI", problem)
            self.assertEqual(gate.select_tip(main, "schedule", NOW), (OTHER_SHA, None, False))

    def test_ci_triggers_skip_the_current_tip_without_network(self):
        main = FakeMain([(NEWER_SHA, "failure"), (SHA, "success")])
        with patch.object(gate, "public_feed", side_effect=AssertionError("network")):
            self.assertEqual(gate.select_tip(main, "workflow_run", NOW), (SHA, "already the current tip", False))


if __name__ == "__main__":
    unittest.main()
