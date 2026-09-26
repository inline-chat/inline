import importlib.util
import hashlib
import io
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("nightly_tip_gate", Path(__file__).with_name("nightly-tip-gate.py"))
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


SHA = "a" * 40
OTHER_SHA = "b" * 40
DIGEST = "c" * 64


def feed_xml(*, signature="signed", version="100", description="Build 100 from commit aaaaaaa."):
    return f'''<?xml version="1.0"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
<description>&lt;p&gt;{description}&lt;/p&gt;</description>
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


if __name__ == "__main__":
    unittest.main()
