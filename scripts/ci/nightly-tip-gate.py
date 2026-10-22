#!/usr/bin/env python3
"""Select green main commits for macOS tip and iOS early tester releases."""

import email.utils
import hashlib
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from datetime import datetime, timedelta, timezone


# Apple releases depend only on Apple Validation (which also regenerates and
# diffs the Swift protocol) plus CodeQL. Server, CLI and integration workflows
# gate their own releases and must not hold back the apps.
REQUIRED_WORKFLOWS = ("apple-validation.yml",)
IOS_STATUS_CONTEXT = "ios/early-testers"
# A commit whose checks are not registered yet is pending, not red.
PENDING_GRACE = timedelta(minutes=30)
TIP_FEED_URL = "https://public-assets.inline.chat/mac/tip/appcast.xml"
SHA_PATTERN = re.compile(r"^[0-9a-f]{40}$")
COMMIT_DESCRIPTION = re.compile(r"from commit ([0-9a-f]{7,40})")
SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
DMG_PATH = re.compile(r"^/mac/tip/([0-9]+)/Inline\.dmg$")
MIN_TIP_INTERVAL = timedelta(hours=1)
MAIN_COMMIT_WINDOW = 50
COMPARE_FILE_LIMIT = 300
# Mirrors selectAppleJobs in validation-gates.mjs: only known non-Apple paths
# can skip a tip build, and unknown inputs fail open to building.
NON_MAC_PATHS = re.compile(r"^(server/|landing/|packages/|plugins/|cli/|crates/|vendor/|skills/|docs/|admin/|\.cargo/|\.codex/|\.agents/|Cargo\.(toml|lock)$|rust-toolchain\.toml$|[^/]+\.md$)")


def require_sha(value):
    if not SHA_PATTERN.fullmatch(value or ""):
        raise ValueError("Expected a full commit SHA from GitHub")
    return value


def latest_push_run(runs, sha):
    matches = [run for run in runs if run.get("head_sha") == sha
               and run.get("head_branch") == "main" and run.get("event") == "push"]
    return max(matches, key=lambda run: run["id"], default=None)


def latest_codeql_check(checks):
    matches = [check for check in checks if check.get("name") == "Analyze (actions)"
               and check.get("app", {}).get("slug") == "github-actions"]
    return max(matches, key=lambda check: check["id"], default=None)


def latest_feed_item(xml):
    root = ET.fromstring(xml)
    items = root.findall("./channel/item")
    if not items:
        raise ValueError("Tip appcast has no release items")
    item = items[-1]
    description = item.findtext("description", default="")
    match = COMMIT_DESCRIPTION.search(description)
    version = item.findtext(f"{{{SPARKLE_NS}}}version", default="").strip()
    short_version = item.findtext(f"{{{SPARKLE_NS}}}shortVersionString", default="").strip()
    hardware = item.findtext(f"{{{SPARKLE_NS}}}hardwareRequirements", default="").strip()
    minimum = item.findtext(f"{{{SPARKLE_NS}}}minimumSystemVersion", default="").strip()
    enclosure = item.find("enclosure")
    if enclosure is None:
        raise ValueError("Latest tip appcast item has no DMG enclosure")
    url = enclosure.get("url", "")
    parsed_url = urllib.parse.urlparse(url)
    dmg_path = DMG_PATH.fullmatch(parsed_url.path)
    signature = enclosure.get(f"{{{SPARKLE_NS}}}edSignature", "")
    if (not version.isdecimal() or not short_version or not minimum
            or hardware != "arm64" or not signature or not dmg_path
            or parsed_url.scheme != "https" or parsed_url.netloc != "public-assets.inline.chat"
            or parsed_url.query or parsed_url.fragment or version != dmg_path.group(1)):
        raise ValueError("Latest tip appcast item lacks valid signed release metadata")
    try:
        size = int(enclosure.get("length", ""))
    except ValueError as error:
        raise ValueError("Latest tip appcast item has no valid DMG length") from error
    if size < 1:
        raise ValueError("Latest tip appcast item has no valid DMG length")
    try:
        published_at = email.utils.parsedate_to_datetime(item.findtext("pubDate", default=""))
    except (TypeError, ValueError):
        published_at = None
    if published_at and published_at.tzinfo is None:
        published_at = published_at.replace(tzinfo=timezone.utc)
    return {
        "commit_prefix": match.group(1) if match else None,
        "dmg_url": url,
        "dmg_size": size,
        "published_at": published_at,
    }


def remote_dmg_sha256(feed_item):
    request = urllib.request.Request(feed_item["dmg_url"], headers={"User-Agent": "inline-nightly-tip-gate"})
    try:
        response = urllib.request.urlopen(request, timeout=30)
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        raise
    digest = hashlib.sha256()
    size = 0
    with response:
        while block := response.read(1024 * 1024):
            size += len(block)
            if size > feed_item["dmg_size"]:
                raise ValueError("Published tip DMG exceeds signed appcast length")
            digest.update(block)
    if size != feed_item["dmg_size"]:
        raise ValueError("Published tip DMG length differs from signed appcast")
    return digest.hexdigest()


def published_tip_matches(sha, tag_sha, release, feed_item, remote_digest):
    if tag_sha != sha or not release or not feed_item or not remote_digest:
        return False
    asset = next((asset for asset in release.get("assets", [])
                  if asset.get("name") == "Inline.dmg" and asset.get("size", 0) > 0), None)
    prefix = feed_item["commit_prefix"]
    return bool(asset and re.fullmatch(r"sha256:[0-9a-f]{64}", asset.get("digest") or "")
                and asset["digest"] == f"sha256:{remote_digest}"
                and prefix and sha.startswith(prefix)
                and feed_item["dmg_size"] == asset["size"]
                and feed_item["dmg_url"].startswith("https://public-assets.inline.chat/mac/tip/"))


def mac_relevant(paths):
    if paths is None:
        return True
    # Swift secure-transport tests consume canonical trust roots from this package.
    if any(path.startswith("packages/protocol/") for path in paths):
        return True
    return not all(NON_MAC_PATHS.match(path) for path in paths)


def changed_paths(comparison):
    files = comparison.get("files")
    if files is None or len(files) >= COMPARE_FILE_LIMIT:
        return None
    paths = []
    for entry in files:
        paths.append(entry["filename"])
        if entry.get("previous_filename"):
            paths.append(entry["previous_filename"])
    return paths


def tip_decision(comparison, feed_item, *, event, now):
    """Return a skip reason for a candidate that differs from the tip, or None to release it."""
    if comparison is not None:
        if comparison["status"] == "behind":
            return "candidate is older than the current tip"
        # A diverged tip (an experimental build) fails open to releasing main.
        if event != "workflow_dispatch" and comparison["status"] == "ahead" \
                and not mac_relevant(changed_paths(comparison)):
            return "no macOS-relevant changes since the current tip"
    published_at = feed_item and feed_item.get("published_at")
    if event != "workflow_dispatch" and published_at and now - published_at < MIN_TIP_INTERVAL:
        return f"last tip was published at {published_at.isoformat()}, under {MIN_TIP_INTERVAL} ago"
    return None


class GitHub:
    def __init__(self, repository, token):
        if repository != "inline-chat/inline":
            raise ValueError("Nightly tip releases are restricted to inline-chat/inline")
        if not token:
            raise ValueError("GITHUB_TOKEN is required")
        self.root = f"https://api.github.com/repos/{repository}"
        self.headers = {
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "inline-nightly-tip-gate",
        }

    def request(self, path, *, missing_ok=False):
        request = urllib.request.Request(f"{self.root}/{path}", headers=self.headers)
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            if missing_ok and error.code == 404:
                return None
            raise

    def tip_commit(self):
        reference = self.request("git/ref/tags/tip", missing_ok=True)
        if reference is None:
            return None
        target = reference["object"]
        for _ in range(3):
            if target["type"] == "commit":
                return require_sha(target["sha"])
            if target["type"] != "tag":
                break
            target = self.request(f"git/tags/{require_sha(target['sha'])}")["object"]
        raise ValueError("tip tag did not resolve to a commit")

    def compare(self, base, head):
        return self.request(f"compare/{base}...{head}")

    def main_push_runs(self, workflow):
        return self.request(f"actions/workflows/{workflow}/runs?branch=main&event=push&per_page=100")["workflow_runs"]

    def main_commits(self):
        return self.request(f"commits?sha=main&per_page={MAIN_COMMIT_WINDOW}")

    def checks(self, sha):
        checks = []
        for page in range(1, 11):
            result = self.request(f"commits/{sha}/check-runs?per_page=100&page={page}")
            checks.extend(result["check_runs"])
            if len(checks) >= result["total_count"]:
                return checks
        raise ValueError("Too many check runs to qualify main")


def public_feed():
    request = urllib.request.Request(TIP_FEED_URL, headers={"User-Agent": "inline-nightly-tip-gate"})
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            return latest_feed_item(response.read())
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        raise


def check_status(label, check):
    if not check:
        return f"{label} is missing", "missing"
    if check.get("status") != "completed":
        return f"{label} is {check.get('status')}/{check.get('conclusion')}", "pending"
    if check.get("conclusion") != "success":
        return f"{label} is completed/{check.get('conclusion')}", "failed"
    return None, "green"


def ci_status(github, sha, runs=None):
    for workflow in REQUIRED_WORKFLOWS:
        if runs is None:
            path = f"actions/workflows/{workflow}/runs?head_sha={sha}&event=push&per_page=100"
            workflow_runs = github.request(path)["workflow_runs"]
        else:
            workflow_runs = runs[workflow]
        problem, state = check_status(workflow, latest_push_run(workflow_runs, sha))
        if problem:
            return problem, state
    return check_status("CodeQL actions analysis", latest_codeql_check(github.checks(sha)))


def ci_problem(github, sha, runs=None):
    return ci_status(github, sha, runs)[0]


def committed_at(commit):
    try:
        return datetime.fromisoformat(commit["commit"]["committer"]["date"].replace("Z", "+00:00"))
    except (KeyError, TypeError, ValueError):
        return None


def newest_green_main(github, is_published, now=None):
    """Return the newest green main commit and the newest commit above it still in CI.

    The walk stops at the last published commit so an older one is never selected.
    """
    runs = {workflow: github.main_push_runs(workflow) for workflow in REQUIRED_WORKFLOWS}
    running = None
    for commit in github.main_commits():
        sha = require_sha(commit["sha"])
        problem, state = ci_status(github, sha, runs)
        if problem is None:
            return sha, running
        print(f"Not green: {sha[:9]} ({problem})")
        committed = committed_at(commit)
        pending = state == "pending" or (state == "missing" and committed and now and now - committed < PENDING_GRACE)
        if running is None and pending:
            running = sha
        if is_published(sha):
            break
    return None, running


# Outcomes shared by every release workflow summary.
RELEASE, CURRENT, DEFERRED, BLOCKED = "release", "already-current", "deferred", "blocked"


def tip_outcome(reason):
    if "older" in reason or "macOS-relevant" in reason:
        return CURRENT
    return DEFERRED


def select_tip(github, event, now):
    """Return (sha, outcome, reason, create_new_appcast)."""
    tag_sha = github.tip_commit()
    sha, running = newest_green_main(github, lambda candidate: candidate == tag_sha, now)
    # Every CI completion retriggers this gate, so wait for newer commits instead
    # of building one that is about to be superseded. The sweep never waits.
    if running and event == "workflow_run":
        return sha, DEFERRED, f"newer main commit {running[:9]} is still in CI", False
    if sha is None:
        return None, BLOCKED, "no green main commit at or after the current tip", False
    if sha == tag_sha and event == "workflow_run":
        # Re-hashing the published DMG on every CI completion would be wasteful,
        # so only the scheduled sweep and manual runs repair a partial publication.
        return sha, CURRENT, "already the current tip", False
    feed = public_feed()
    if sha == tag_sha:
        release = github.request("releases/tags/tip", missing_ok=True)
        digest = remote_dmg_sha256(feed) if release and feed else None
        if published_tip_matches(sha, tag_sha, release, feed, digest):
            return sha, CURRENT, "already published", False
        return sha, RELEASE, "repairing a partial tip publication", feed is None
    comparison = github.compare(tag_sha, sha) if tag_sha else None
    problem = tip_decision(comparison, feed, event=event, now=now)
    if problem:
        return sha, tip_outcome(problem), problem, False
    return sha, RELEASE, "newer green main commit", feed is None


def ios_published(github, sha):
    statuses = github.request(f"commits/{sha}/statuses?per_page=100")
    status = next((item for item in statuses if item.get("context") == IOS_STATUS_CONTEXT), None)
    return bool(status and status.get("state") == "success"
                and status.get("creator", {}).get("login") == "github-actions[bot]")


def select_ios(github, event, now):
    """Return (sha, outcome, reason) for internal Early Testers."""
    sha, running = newest_green_main(github, lambda candidate: ios_published(github, candidate), now)
    if running and event == "workflow_run":
        return sha, DEFERRED, f"newer main commit {running[:9]} is still in CI"
    if sha is None:
        return None, BLOCKED, "no green main commit since the last Early Testers build"
    # Scheduled and manual runs still resume the publisher, which is idempotent
    # and refreshes a build approaching TestFlight expiry.
    if event == "workflow_run" and ios_published(github, sha):
        return sha, CURRENT, "already available to Early Testers"
    return sha, RELEASE, "newest green main commit"


def qualify_commit(github, sha):
    """A selected commit stays releasable while it is green and on main, even if main moves on."""
    # GitHub can briefly omit a just-completed run. Recheck only missing/pending
    # results, never a completed failure, and still fail closed after three reads.
    for attempt in range(3):
        problem, state = ci_status(github, sha)
        if not problem:
            break
        if state == "failed" or attempt == 2:
            raise ValueError(f"Selected commit {sha} is no longer green: {problem}")
        time.sleep(2)
    if github.compare(sha, "main")["status"] not in ("ahead", "identical"):
        raise ValueError(f"Selected commit {sha} is not on main")


def qualify_tip(github, sha):
    qualify_commit(github, sha)
    tag_sha = github.tip_commit()
    if tag_sha and tag_sha != sha and github.compare(tag_sha, sha)["status"] == "behind":
        raise ValueError(f"Selected commit {sha} is older than the current tip {tag_sha}")


def output(**values):
    target = os.environ.get("GITHUB_OUTPUT")
    if not target:
        raise ValueError("GITHUB_OUTPUT is required")
    with open(target, "a", encoding="utf-8") as stream:
        for key, value in values.items():
            stream.write(f"{key}={value}\n")


def decide(label, event, sha, outcome, reason, **extra):
    print(f"{label} ({event}): {outcome}: {reason}{f' ({sha})' if sha else ''}")
    output(sha=sha or "", should_release=str(outcome == RELEASE).lower(),
           outcome=outcome, reason=reason, **extra)


def main():
    github = GitHub(os.environ.get("GITHUB_REPOSITORY"), os.environ.get("GH_TOKEN"))
    mode = sys.argv[1] if len(sys.argv) > 1 else "select"
    event = os.environ.get("GITHUB_EVENT_NAME", "workflow_dispatch")
    if mode == "select-ios":
        sha, outcome, reason = select_ios(github, event, datetime.now(timezone.utc))
        decide("iOS Early Testers", event, sha, outcome, reason)
    elif mode == "select":
        sha, outcome, reason, create_new_appcast = select_tip(github, event, datetime.now(timezone.utc))
        decide("macOS tip", event, sha, outcome, reason,
               create_new_appcast=str(create_new_appcast).lower())
    elif mode == "qualify":
        sha = require_sha(os.environ.get("EXPECTED_SHA"))
        qualify_commit(github, sha)
        print(f"Requalified green main commit: {sha}")
    elif mode == "qualify-tip":
        sha = require_sha(os.environ.get("EXPECTED_SHA"))
        qualify_tip(github, sha)
        print(f"Requalified green main commit for tip: {sha}")
    elif mode == "verify":
        sha = require_sha(os.environ.get("EXPECTED_SHA"))
        tag_sha = github.tip_commit()
        release = github.request("releases/tags/tip", missing_ok=True)
        feed = public_feed()
        remote_digest = remote_dmg_sha256(feed) if feed else None
        if not published_tip_matches(sha, tag_sha, release, feed, remote_digest):
            raise ValueError(f"Published tip artifacts do not agree on source commit {sha}")
        print(f"Verified GitHub tip tag, DMG asset, and current Sparkle feed for {sha}")
    else:
        raise ValueError(f"Unknown mode: {mode}")


if __name__ == "__main__":
    main()
