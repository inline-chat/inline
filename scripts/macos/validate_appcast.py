"""
Validate Sparkle appcast output.

Checks:
  - at least one <item>
  - sparkle:version + sparkle:shortVersionString present
  - enclosure has url + sparkle:edSignature + length
  - optional: require a specific build number and dmg URL
"""

from __future__ import annotations

import argparse
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def sparkle_tag(name: str) -> str:
    return f"{{{SPARKLE_NS}}}{name}"


def find_sparkle_child(item: ET.Element, name: str) -> ET.Element | None:
    element = item.find(sparkle_tag(name))
    if element is None:
        element = item.find(f"sparkle:{name}", {"sparkle": SPARKLE_NS})
    return element


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--appcast", required=True)
    parser.add_argument("--require-build")
    parser.add_argument("--require-url")
    args = parser.parse_args()

    appcast_path = Path(args.appcast)
    if not appcast_path.exists():
        print(f"Appcast not found: {appcast_path}", file=sys.stderr)
        return 1

    try:
        tree = ET.parse(appcast_path)
    except ET.ParseError as error:
        print(f"Appcast XML parse error: {error}", file=sys.stderr)
        return 1

    root = tree.getroot()
    def has_sparkle_namespace() -> bool:
        for el in root.iter():
            if isinstance(el.tag, str) and el.tag.startswith(f"{{{SPARKLE_NS}}}"):
                return True
            for attr in el.attrib:
                if attr.startswith(f"{{{SPARKLE_NS}}}"):
                    return True
        return False

    if not has_sparkle_namespace():
        print("Appcast missing Sparkle namespace usage", file=sys.stderr)
        return 1

    channel = root.find("channel")
    if channel is None:
        channel = root.find("./channel")
    if channel is None:
        print("Appcast missing <channel>", file=sys.stderr)
        return 1

    items = channel.findall("item")
    if not items:
        print("Appcast has no <item> entries", file=sys.stderr)
        return 1

    if args.require_build:
        if not any(
            (find_sparkle_child(item, "version") is not None)
            and (find_sparkle_child(item, "version").text == args.require_build)
            for item in items
        ):
            print(f"Appcast missing build {args.require_build}", file=sys.stderr)
            return 1

    if args.require_url:
        if not any(
            (item.find("enclosure") is not None)
            and (item.find("enclosure").get("url") == args.require_url)
            for item in items
        ):
            print(f"Appcast missing enclosure URL {args.require_url}", file=sys.stderr)
            return 1

    for item in items:
        version_el = find_sparkle_child(item, "version")
        short_el = find_sparkle_child(item, "shortVersionString")
        if version_el is None or not (version_el.text or "").strip():
            print("Missing sparkle:version", file=sys.stderr)
            return 1
        if short_el is None or not (short_el.text or "").strip():
            print("Missing sparkle:shortVersionString", file=sys.stderr)
            return 1

        enclosure = item.find("enclosure")
        if enclosure is None:
            print("Missing enclosure", file=sys.stderr)
            return 1

        url = enclosure.get("url")
        if not url:
            print("Missing enclosure url", file=sys.stderr)
            return 1

        edsig = enclosure.get(sparkle_tag("edSignature")) or enclosure.get("sparkle:edSignature")
        if not edsig:
            print("Missing sparkle:edSignature", file=sys.stderr)
            return 1

        length = enclosure.get("length")
        if not length:
            print("Missing enclosure length", file=sys.stderr)
            return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
