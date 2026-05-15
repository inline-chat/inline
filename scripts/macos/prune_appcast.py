"""
Remove one stale Sparkle appcast item by build number.

This is for cleaning a bad middle appcast item while keeping the current latest
build live. To move the latest build back, use rollback_appcast.py instead.
"""

from __future__ import annotations

import argparse
import json
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE_NS)


def sparkle_tag(name: str) -> str:
    return f"{{{SPARKLE_NS}}}{name}"


def find_sparkle_child(item: ET.Element, name: str) -> ET.Element | None:
    element = item.find(sparkle_tag(name))
    if element is None:
        element = item.find(f"sparkle:{name}", {"sparkle": SPARKLE_NS})
    if element is None:
        element = item.find(f"sparkle:{name}")
    return element


def item_build(item: ET.Element) -> str:
    version = find_sparkle_child(item, "version")
    return (version.text or "").strip() if version is not None else ""


def item_url(item: ET.Element) -> str:
    enclosure = item.find("enclosure")
    return (enclosure.get("url") or "").strip() if enclosure is not None else ""


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--appcast", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--metadata-output", required=True)
    parser.add_argument("--drop-build", required=True)
    args = parser.parse_args()

    appcast_path = Path(args.appcast)
    output_path = Path(args.output)
    metadata_path = Path(args.metadata_output)

    if not appcast_path.exists():
        print(f"Appcast not found: {appcast_path}", file=sys.stderr)
        return 1

    try:
        tree = ET.parse(appcast_path)
    except ET.ParseError as error:
        print(f"Appcast XML parse error: {error}", file=sys.stderr)
        return 1

    root = tree.getroot()
    channel = root.find("channel")
    if channel is None:
        print("Appcast missing <channel>", file=sys.stderr)
        return 1

    items = channel.findall("item")
    if len(items) < 2:
        print("Cannot prune an appcast with fewer than two items.", file=sys.stderr)
        return 1

    matches = [index for index, item in enumerate(items) if item_build(item) == args.drop_build]
    if not matches:
        print(f"Build not found in appcast: {args.drop_build}", file=sys.stderr)
        return 1
    if len(matches) > 1:
        print(f"Build appears more than once in appcast: {args.drop_build}", file=sys.stderr)
        return 1

    drop_index = matches[0]
    if drop_index == len(items) - 1:
        print("Refusing to drop the latest appcast item; use --rollback instead.", file=sys.stderr)
        return 1

    dropped_item = items[drop_index]
    dropped_url = item_url(dropped_item)
    if not dropped_url:
        print("Selected item is missing enclosure url.", file=sys.stderr)
        return 1

    channel.remove(dropped_item)
    remaining_items = channel.findall("item")
    latest_item = remaining_items[-1]
    latest_build = item_build(latest_item)
    latest_url = item_url(latest_item)
    if not latest_build:
        print("Latest remaining item is missing sparkle:version.", file=sys.stderr)
        return 1
    if not latest_url:
        print("Latest remaining item is missing enclosure url.", file=sys.stderr)
        return 1

    remaining_builds = [build for build in (item_build(item) for item in remaining_items) if build]

    output_path.parent.mkdir(parents=True, exist_ok=True)
    tree.write(output_path, xml_declaration=True, encoding="utf-8")
    metadata_path.parent.mkdir(parents=True, exist_ok=True)
    metadata_path.write_text(
        json.dumps(
            {
                "droppedBuild": args.drop_build,
                "droppedUrl": dropped_url,
                "latestBuild": latest_build,
                "latestUrl": latest_url,
                "remainingBuilds": remaining_builds,
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )

    print(f"Dropped build: {args.drop_build}")
    print(f"Dropped url: {dropped_url}")
    print(f"Latest remaining build: {latest_build}")
    print(f"Latest remaining url: {latest_url}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
