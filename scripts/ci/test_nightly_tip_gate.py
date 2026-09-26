import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("nightly_tip_gate", Path(__file__).with_name("nightly-tip-gate.py"))
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


SHA = "a" * 40
OTHER_SHA = "b" * 40


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

    def test_skip_requires_matching_tag_release_asset_and_latest_feed(self):
        feed = gate.latest_feed_item(b'''<?xml version="1.0"?>
<rss><channel><item><description>&lt;p&gt;Build 100 from commit aaaaaaa.&lt;/p&gt;</description>
<enclosure url="https://public-assets.inline.chat/mac/tip/100/Inline.dmg" length="123" />
</item></channel></rss>''')
        release = {"assets": [{"name": "Inline.dmg", "size": 123}]}
        self.assertTrue(gate.published_tip_matches(SHA, SHA, release, feed))
        self.assertFalse(gate.published_tip_matches(SHA, OTHER_SHA, release, feed))
        self.assertFalse(gate.published_tip_matches(SHA, SHA, {"assets": []}, feed))
        self.assertFalse(gate.published_tip_matches(SHA, SHA, release, {**feed, "dmg_size": 124}))
        self.assertFalse(gate.published_tip_matches(SHA, SHA, release, {**feed, "commit_prefix": "bbbbbbb"}))

    def test_invalid_appcast_cannot_masquerade_as_first_publication(self):
        with self.assertRaises(ValueError):
            gate.latest_feed_item(b"<rss><channel /></rss>")
        with self.assertRaises(ValueError):
            gate.latest_feed_item(b"<rss><channel><item /></channel></rss>")


if __name__ == "__main__":
    unittest.main()
