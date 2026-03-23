"""
Generate a rolled-back Sparkle appcast by removing newer entries.

This is intended for release incident response where an older DMG still exists
at its immutable URL and the live appcast needs to move back to it.
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
    parser.add_argument("--target-build")
    parser.add_argument("--steps-back", type=int, default=1)
    args = parser.parse_args()

    if args.target_build and args.steps_back != 1:
        print("Use either --target-build or --steps-back, not both.", file=sys.stderr)
        return 1
    if args.steps_back < 1:
        print("--steps-back must be >= 1", file=sys.stderr)
        return 1

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
    if not items:
        print("Appcast has no <item> entries", file=sys.stderr)
        return 1

    selected_index: int | None = None
    if args.target_build:
        for index, item in enumerate(items):
            if item_build(item) == args.target_build:
                selected_index = index
                break
        if selected_index is None:
            print(f"Build not found in appcast: {args.target_build}", file=sys.stderr)
            return 1
    else:
        selected_index = len(items) - 1 - args.steps_back
        if selected_index < 0:
            print(
                f"Cannot roll back {args.steps_back} step(s); appcast only has {len(items)} item(s).",
                file=sys.stderr,
            )
            return 1

    if selected_index >= len(items) - 1:
        print("Selected rollback target is already the latest appcast item.", file=sys.stderr)
        return 1

    selected_item = items[selected_index]
    selected_build = item_build(selected_item)
    selected_url = item_url(selected_item)
    if not selected_build:
        print("Selected rollback target is missing sparkle:version.", file=sys.stderr)
        return 1
    if not selected_url:
        print("Selected rollback target is missing enclosure url.", file=sys.stderr)
        return 1

    removed_builds: list[str] = []
    for item in items[selected_index + 1 :]:
        build = item_build(item)
        if build:
            removed_builds.append(build)
        channel.remove(item)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    tree.write(output_path, xml_declaration=True, encoding="utf-8")
    metadata_path.parent.mkdir(parents=True, exist_ok=True)
    metadata_path.write_text(
      json.dumps(
        {
          "selectedBuild": selected_build,
          "selectedUrl": selected_url,
          "removedBuilds": removed_builds,
        },
        indent=2,
      )
      + "\n",
      encoding="utf-8",
    )

    print(f"Selected rollback build: {selected_build}")
    print(f"Selected rollback url: {selected_url}")
    if removed_builds:
      print(f"Removed newer builds: {', '.join(removed_builds)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
