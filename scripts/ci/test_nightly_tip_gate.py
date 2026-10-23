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

    def __init__(self, commits, tip=SHA, comparison=None, published=(), committed=None):
        self.commits = commits
        self.tip = tip
        self.published = set(published)
        self.committed = committed or {}
        self.codeql = {}
        self.comparison = comparison or {"status": "ahead", "files": [{"filename": "apple/InlineMac/App.swift"}]}
        self.runs = {name: [] for name in gate.REQUIRED_WORKFLOWS}
        for index, (sha, state) in enumerate(reversed(commits)):
            if state == "missing":
                continue
            for name in gate.REQUIRED_WORKFLOWS:
                status, conclusion = ("in_progress", None) if state == "running" else ("completed", state)
                self.runs[name].append(run(index + 1, sha=sha, status=status, conclusion=conclusion))

    def tip_commit(self):
        return self.tip

    def main_push_runs(self, workflow):
        return self.runs[workflow]

    def main_commits(self):
        return [{"sha": sha, "commit": {"committer": {"date": self.committed.get(sha, "2026-10-19T00:00:00Z")}}}
                for sha, _ in self.commits]

    def compare(self, base, head):
        return self.comparison

    def checks(self, sha):
        return self.codeql.get(sha, FakeGitHub().codeql)

    def request(self, path, missing_ok=False):
        match = re.fullmatch(r"commits/([0-9a-f]{40})/statuses\?per_page=100", path)
        if not match:
            raise AssertionError(f"unexpected request {path}")
        if match.group(1) not in self.published:
            return []
        return [{"context": gate.IOS_STATUS_CONTEXT, "state": "success", "creator": {"login": "github-actions[bot]"}}]


class NightlyTipGateTests(unittest.TestCase):
    def test_apple_validation_and_codeql_must_be_green(self):
        github = FakeGitHub()
        self.assertIsNone(gate.ci_problem(github, SHA))
        github.runs["apple-validation.yml"] = [run(9), run(10, sha=OTHER_SHA)]
        self.assertIsNone(gate.ci_problem(github, SHA))
        github.runs["apple-validation.yml"].append(run(11, status="in_progress", conclusion=None))
        self.assertIn("in_progress", gate.ci_problem(github, SHA))
        github.runs["apple-validation.yml"][-1] = run(11, conclusion="failure")
        self.assertIn("failure", gate.ci_problem(github, SHA))
        github.runs["apple-validation.yml"][-1] = run(11)
        github.codeql[0]["conclusion"] = "failure"
        self.assertIn("CodeQL", gate.ci_problem(github, SHA))

    def test_missing_required_run_fails_closed(self):
        github = FakeGitHub()
        github.runs["apple-validation.yml"] = [run(1, sha=OTHER_SHA)]
        self.assertIn("missing", gate.ci_problem(github, SHA))

    def test_server_cli_and_integration_workflows_do_not_gate_apple_releases(self):
        self.assertEqual(gate.REQUIRED_WORKFLOWS, ("apple-validation.yml",))

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


class MacChannelTests(unittest.TestCase):
    def test_beta_feed_cannot_accept_tip_artifacts(self):
        beta_xml = feed_xml().replace(b"/mac/tip/", b"/mac/beta/")
        feed = gate.latest_feed_item(beta_xml, "beta")
        release = {"assets": [{"name": "Inline.dmg", "size": 123, "digest": f"sha256:{DIGEST}"}]}
        self.assertTrue(gate.published_tip_matches(SHA, SHA, release, feed, DIGEST, "beta"))
        self.assertFalse(gate.published_tip_matches(SHA, SHA, release, feed, DIGEST))
        for xml, channel in [(feed_xml(), "beta"), (beta_xml, "tip")]:
            with self.assertRaises(ValueError):
                gate.latest_feed_item(xml, channel)
        with self.assertRaises(ValueError):
            gate.require_channel("stable")

    def test_beta_uses_its_own_tag_and_feed(self):
        github = gate.GitHub("inline-chat/inline", "test-token", "beta")
        with patch.object(github, "request", return_value={"object": {"type": "commit", "sha": SHA}}) as request:
            self.assertEqual(github.tip_commit(), SHA)
        request.assert_called_once_with("git/ref/tags/beta", missing_ok=True)
        beta_xml = feed_xml().replace(b"/mac/tip/", b"/mac/beta/")
        with patch.object(gate.urllib.request, "urlopen", return_value=io.BytesIO(beta_xml)) as fetch:
            gate.public_feed("beta")
        self.assertEqual(fetch.call_args.args[0].full_url,
                         "https://public-assets.inline.chat/mac/beta/appcast.xml")

    def test_manual_beta_builds_newest_green_main_without_tip_cadence(self):
        main = FakeMain([(NEWEST_SHA, "running"), (NEWER_SHA, "success"), (SHA, "success")],
                        comparison={"status": "ahead", "files": [{"filename": "server/a.ts"}]})
        with patch.object(gate, "public_feed", return_value={"published_at": NOW}) as feed:
            result = gate.select_tip(main, "workflow_dispatch", NOW, "beta")
        self.assertEqual(result[:2], (NEWER_SHA, gate.RELEASE))
        feed.assert_called_once_with("beta")

    def test_beta_rerun_verifies_existing_artifacts_before_skipping(self):
        main = FakeMain([(SHA, "success")])
        feed = gate.latest_feed_item(feed_xml().replace(b"/mac/tip/", b"/mac/beta/"), "beta")
        release = {"assets": [{"name": "Inline.dmg", "size": 123, "digest": f"sha256:{DIGEST}"}]}
        with patch.object(main, "request", return_value=release) as request, \
                patch.object(gate, "public_feed", return_value=feed), \
                patch.object(gate, "remote_dmg_sha256", return_value=DIGEST):
            self.assertEqual(gate.select_tip(main, "workflow_dispatch", NOW, "beta")[1], gate.CURRENT)
            request.assert_called_with("releases/tags/beta", missing_ok=True)
            release["assets"] = []
            self.assertEqual(gate.select_tip(main, "workflow_dispatch", NOW, "beta")[1], gate.RELEASE)

    def test_beta_rejects_downgrades(self):
        github = FakeGitHub()
        github.tip_commit = lambda: NEWER_SHA
        github.compare = lambda base, head: {"status": "behind" if base == NEWER_SHA else "ahead"}
        with self.assertRaisesRegex(ValueError, "older than the current beta"):
            gate.qualify_tip(github, SHA, "beta")


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
        at_tip = lambda sha: sha == SHA
        self.assertEqual(gate.newest_green_main(main, at_tip), (NEWER_SHA, NEWEST_SHA))
        main = FakeMain([(NEWER_SHA, "cancelled"), (OTHER_SHA, "failure"), (SHA, "success")])
        self.assertEqual(gate.newest_green_main(main, at_tip), (SHA, None))
        main = FakeMain([(NEWER_SHA, "failure"), (SHA, "failure"), (OTHER_SHA, "success")])
        self.assertEqual(gate.newest_green_main(main, at_tip), (None, None))

    def test_recent_commits_without_registered_checks_are_pending_not_red(self):
        main = FakeMain([(NEWER_SHA, "missing"), (SHA, "success")],
                        committed={NEWER_SHA: (NOW - timedelta(minutes=5)).isoformat()})
        self.assertEqual(gate.newest_green_main(main, lambda sha: False, NOW), (SHA, NEWER_SHA))
        main.committed[NEWER_SHA] = (NOW - timedelta(hours=2)).isoformat()
        self.assertEqual(gate.newest_green_main(main, lambda sha: False, NOW), (SHA, None))

    def test_codeql_pending_or_recently_missing_is_reported_as_pending(self):
        main = FakeMain([(NEWER_SHA, "success"), (SHA, "success")],
                        committed={NEWER_SHA: (NOW - timedelta(minutes=5)).isoformat()})
        main.codeql[NEWER_SHA] = [{**FakeGitHub().codeql[0], "status": "in_progress", "conclusion": None}]
        self.assertEqual(gate.newest_green_main(main, lambda sha: False, NOW), (SHA, NEWER_SHA))
        self.assertEqual(gate.select_ios(main, "workflow_run", NOW)[:2], (SHA, gate.DEFERRED))
        self.assertEqual(gate.select_tip(main, "workflow_run", NOW)[:2], (SHA, gate.DEFERRED))
        main.codeql[NEWER_SHA] = []
        self.assertEqual(gate.newest_green_main(main, lambda sha: False, NOW), (SHA, NEWER_SHA))
        main.committed[NEWER_SHA] = (NOW - timedelta(hours=2)).isoformat()
        self.assertEqual(gate.newest_green_main(main, lambda sha: False, NOW), (SHA, None))
        main.codeql[NEWER_SHA] = [{**FakeGitHub().codeql[0], "conclusion": "failure"}]
        self.assertEqual(gate.newest_green_main(main, lambda sha: False, NOW), (SHA, None))

    def test_ci_triggers_wait_for_newer_commits_but_the_sweep_does_not(self):
        main = FakeMain([(NEWER_SHA, "running"), (OTHER_SHA, "success"), (SHA, "success")])
        feed = {"published_at": NOW - timedelta(hours=2)}
        with patch.object(gate, "public_feed", return_value=feed):
            sha, outcome, reason, _ = gate.select_tip(main, "workflow_run", NOW)
            self.assertEqual((sha, outcome), (OTHER_SHA, gate.DEFERRED))
            self.assertIn("still in CI", reason)
            self.assertEqual(gate.select_tip(main, "schedule", NOW)[:2], (OTHER_SHA, gate.RELEASE))

    def test_ci_triggers_skip_the_current_tip_without_network(self):
        main = FakeMain([(NEWER_SHA, "failure"), (SHA, "success")])
        with patch.object(gate, "public_feed", side_effect=AssertionError("network")):
            self.assertEqual(gate.select_tip(main, "workflow_run", NOW),
                             (SHA, gate.CURRENT, "already the current tip", False))

    def test_tip_skip_reasons_map_to_outcomes(self):
        self.assertEqual(gate.tip_outcome("candidate is older than the current tip"), gate.CURRENT)
        self.assertEqual(gate.tip_outcome("no macOS-relevant changes since the current tip"), gate.CURRENT)
        self.assertEqual(gate.tip_outcome("last tip was published at x, under 1:00:00 ago"), gate.DEFERRED)


class CandidateStabilityTests(unittest.TestCase):
    def test_selected_commit_stays_releasable_after_main_moves_on(self):
        github = FakeGitHub()
        github.compare = lambda base, head: {"status": "ahead"}
        gate.qualify_commit(github, SHA)
        github.compare = lambda base, head: {"status": "identical"}
        gate.qualify_commit(github, SHA)

    def test_commit_off_main_or_red_is_rejected(self):
        github = FakeGitHub()
        github.compare = lambda base, head: {"status": "diverged"}
        with self.assertRaisesRegex(ValueError, "not on main"):
            gate.qualify_commit(github, SHA)
        github.compare = lambda base, head: {"status": "ahead"}
        github.runs["apple-validation.yml"] = [run(11, conclusion="failure")]
        with patch.object(gate.time, "sleep", side_effect=AssertionError("must not retry a failure")):
            with self.assertRaisesRegex(ValueError, "no longer green"):
                gate.qualify_commit(github, SHA)

    def test_qualification_retries_delayed_apple_and_codeql_results(self):
        for delayed in ("apple", "codeql"):
            with self.subTest(delayed=delayed):
                github = FakeGitHub()
                github.compare = lambda base, head: {"status": "ahead"}
                if delayed == "apple":
                    github.runs["apple-validation.yml"] = []
                else:
                    github.codeql[0].update(status="in_progress", conclusion=None)

                def finish_checks(_):
                    github.runs["apple-validation.yml"] = [run(10)]
                    github.codeql[0].update(status="completed", conclusion="success")

                with patch.object(gate.time, "sleep", side_effect=finish_checks) as pause:
                    gate.qualify_commit(github, SHA)
                pause.assert_called_once_with(2)

    def test_missing_or_pending_checks_still_fail_closed_after_bounded_retries(self):
        for status in ("missing", "pending"):
            with self.subTest(status=status):
                github = FakeGitHub()
                github.runs["apple-validation.yml"] = [] if status == "missing" else [
                    run(10, status="in_progress", conclusion=None)]
                with patch.object(gate.time, "sleep") as pause, patch.object(github, "request", wraps=github.request) as request:
                    with self.assertRaisesRegex(ValueError, "no longer green"):
                        gate.qualify_commit(github, SHA)
                self.assertEqual(request.call_count, 3)
                self.assertEqual(pause.call_count, 2)


class IosSelectionTests(unittest.TestCase):
    def test_newest_green_commit_after_the_last_build_is_released(self):
        main = FakeMain([(NEWER_SHA, "failure"), (OTHER_SHA, "success"), (SHA, "success")], published=[SHA])
        self.assertEqual(gate.select_ios(main, "workflow_run", NOW), (OTHER_SHA, gate.RELEASE, "newest green main commit"))

    def test_published_commit_is_current_on_ci_events_but_resumed_by_the_sweep(self):
        main = FakeMain([(NEWER_SHA, "failure"), (SHA, "success")], published=[SHA])
        self.assertEqual(gate.select_ios(main, "workflow_run", NOW)[:2], (SHA, gate.CURRENT))
        self.assertEqual(gate.select_ios(main, "schedule", NOW)[:2], (SHA, gate.RELEASE))

    def test_walk_never_passes_the_last_build(self):
        main = FakeMain([(NEWER_SHA, "failure"), (SHA, "failure"), (OTHER_SHA, "success")], published=[SHA])
        self.assertEqual(gate.select_ios(main, "schedule", NOW)[:2], (None, gate.BLOCKED))

    def test_ci_events_wait_for_newer_commits(self):
        main = FakeMain([(NEWER_SHA, "running"), (SHA, "success")])
        self.assertEqual(gate.select_ios(main, "workflow_run", NOW)[:2], (SHA, gate.DEFERRED))


if __name__ == "__main__":
    unittest.main()
