#!/usr/bin/env python3
"""Select the current green main commit for a macOS tip release."""

import json
import os
import re
import sys
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET


REQUIRED_WORKFLOWS = (
    "integrations.yml",
    "apple-validation.yml",
    "server-test.yml",
)
TIP_FEED_URL = "https://public-assets.inline.chat/mac/tip/appcast.xml"
SHA_PATTERN = re.compile(r"^[0-9a-f]{40}$")
COMMIT_DESCRIPTION = re.compile(r"from commit ([0-9a-f]{7,40})")


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
    enclosure = item.find("enclosure")
    if enclosure is None or not enclosure.get("url") or not enclosure.get("length"):
        raise ValueError("Latest tip appcast item has no complete DMG enclosure")
    return {
        "commit_prefix": match.group(1) if match else None,
        "dmg_url": enclosure.get("url"),
        "dmg_size": int(enclosure.get("length")),
    }


def published_tip_matches(sha, tag_sha, release, feed_item):
    if tag_sha != sha or not release or not feed_item:
        return False
    asset = next((asset for asset in release.get("assets", [])
                  if asset.get("name") == "Inline.dmg" and asset.get("size", 0) > 0), None)
    prefix = feed_item["commit_prefix"]
    return bool(asset and prefix and sha.startswith(prefix)
                and feed_item["dmg_size"] == asset["size"]
                and feed_item["dmg_url"].startswith("https://public-assets.inline.chat/mac/tip/")
                and feed_item["dmg_url"].endswith("/Inline.dmg"))


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


def inspect_main(github):
    sha = require_sha(github.request("git/ref/heads/main")["object"]["sha"])
    for workflow in REQUIRED_WORKFLOWS:
        path = f"actions/workflows/{workflow}/runs?head_sha={sha}&event=push&per_page=100"
        run = latest_push_run(github.request(path)["workflow_runs"], sha)
        if not run or run.get("status") != "completed" or run.get("conclusion") != "success":
            state = f"{run.get('status')}/{run.get('conclusion')}" if run else "missing"
            return sha, f"{workflow} is {state} for latest main"
    check = latest_codeql_check(github.checks(sha))
    if not check or check.get("status") != "completed" or check.get("conclusion") != "success":
        state = f"{check.get('status')}/{check.get('conclusion')}" if check else "missing"
        return sha, f"CodeQL actions analysis is {state} for latest main"
    return sha, None


def output(**values):
    target = os.environ.get("GITHUB_OUTPUT")
    if not target:
        raise ValueError("GITHUB_OUTPUT is required")
    with open(target, "a", encoding="utf-8") as stream:
        for key, value in values.items():
            stream.write(f"{key}={value}\n")


def main():
    github = GitHub(os.environ.get("GITHUB_REPOSITORY"), os.environ.get("GH_TOKEN"))
    mode = sys.argv[1] if len(sys.argv) > 1 else "select"
    if mode == "select":
        sha, problem = inspect_main(github)
        if problem:
            print(f"Skipping nightly tip: {problem} ({sha})")
            output(sha=sha, should_release="false", create_new_appcast="false")
            return
        tag_sha = github.tip_commit()
        release = github.request("releases/tags/tip", missing_ok=True)
        feed = public_feed()
        already_released = published_tip_matches(sha, tag_sha, release, feed)
        print(f"Latest green main: {sha}; already published: {already_released}")
        output(sha=sha, should_release=str(not already_released).lower(),
               create_new_appcast=str(feed is None).lower())
    elif mode == "verify":
        sha = require_sha(os.environ.get("EXPECTED_SHA"))
        tag_sha = github.tip_commit()
        release = github.request("releases/tags/tip", missing_ok=True)
        feed = public_feed()
        if not published_tip_matches(sha, tag_sha, release, feed):
            raise ValueError(f"Published tip artifacts do not agree on source commit {sha}")
        print(f"Verified GitHub tip tag, DMG asset, and current Sparkle feed for {sha}")
    else:
        raise ValueError(f"Unknown mode: {mode}")


if __name__ == "__main__":
    main()
