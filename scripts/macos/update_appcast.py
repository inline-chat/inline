"""
Generate or update a Sparkle appcast for Inline macOS builds.

Inputs:
  - sign_update.txt: output from Sparkle `sign_update`
  - appcast.xml: existing appcast (optional)

Environment:
  - INLINE_BUILD
  - INLINE_VERSION
  - INLINE_CHANNEL
  - INLINE_DMG_URL
  - INLINE_MIN_MACOS (optional, default: 15.0)
  - INLINE_COMMIT (optional)
  - INLINE_COMMIT_LONG (optional)

Output:
  - appcast_new.xml
"""

import os
import sys
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from pathlib import Path

build = os.environ["INLINE_BUILD"]
version = os.environ.get("INLINE_VERSION", build)
channel = os.environ.get("INLINE_CHANNEL", "stable")
dmg_url = os.environ["INLINE_DMG_URL"]
min_macos = os.environ.get("INLINE_MIN_MACOS", "15.0")
commit = os.environ.get("INLINE_COMMIT", "")
commit_long = os.environ.get("INLINE_COMMIT_LONG", "")

appcast_path = Path(os.environ.get("APPCAST_PATH", "appcast.xml"))
output_path = Path(os.environ.get("APPCAST_OUTPUT", "appcast_new.xml"))
sign_update_path = Path(os.environ.get("SIGN_UPDATE_PATH", "sign_update.txt"))

now = datetime.now(timezone.utc)

# Read sign_update output
attrs = {}
with open(sign_update_path, "r", encoding="utf-8") as f:
    for pair in f.read().split(" "):
        key, value = pair.split("=", 1)
        value = value.strip()
        if value and value[0] == '"':
            value = value[1:-1]
        attrs[key] = value

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
namespaces = {"sparkle": SPARKLE_NS}
ET.register_namespace("sparkle", SPARKLE_NS)

def sparkle_tag(name: str) -> str:
    return f"{{{SPARKLE_NS}}}{name}"

def find_sparkle_child(item: ET.Element, name: str) -> ET.Element | None:
    return (
        item.find(sparkle_tag(name))
        or item.find(f"sparkle:{name}", namespaces)
        or item.find(f"sparkle:{name}")
    )

if appcast_path.exists():
    try:
        et = ET.parse(appcast_path)
        root = et.getroot()
    except ET.ParseError as error:
        print(f"Warning: failed to parse existing appcast ({appcast_path}): {error}", file=sys.stderr)
        root = ET.Element("rss", {"version": "2.0"})
        et = ET.ElementTree(root)
else:
    root = ET.Element("rss", {"version": "2.0"})
    et = ET.ElementTree(root)

channel_el = root.find("channel")
if channel_el is None:
    channel_el = ET.SubElement(root, "channel")
    title = ET.SubElement(channel_el, "title")
    title.text = f"Inline macOS ({channel})"
    link = ET.SubElement(channel_el, "link")
    link.text = "https://inline.chat"
    description = ET.SubElement(channel_el, "description")
    description.text = "Inline macOS updates"

# Remove any existing item with the same build number
for item in list(channel_el.findall("item")):
    version_el = find_sparkle_child(item, "version")
    if version_el is not None and version_el.text == build:
        channel_el.remove(item)

item = ET.SubElement(channel_el, "item")

item_title = ET.SubElement(item, "title")
item_title.text = f"Inline {version}"

pub_date = ET.SubElement(item, "pubDate")
pub_date.text = now.strftime("%a, %d %b %Y %H:%M:%S %z")

sparkle_version = ET.SubElement(item, sparkle_tag("version"))
sparkle_version.text = build

sparkle_short = ET.SubElement(item, sparkle_tag("shortVersionString"))
sparkle_short.text = version

sparkle_min = ET.SubElement(item, sparkle_tag("minimumSystemVersion"))
sparkle_min.text = min_macos

if commit:
    description = ET.SubElement(item, "description")
    description.text = f"<p>Build {build} from commit {commit}.</p>"

enclosure = ET.SubElement(item, "enclosure")
enclosure.set("url", dmg_url)
enclosure.set("type", "application/octet-stream")
for key, value in attrs.items():
    if key.startswith("sparkle:"):
        enclosure.set(sparkle_tag(key.split(":", 1)[1]), value)
    else:
        enclosure.set(key, value)

output_path.parent.mkdir(parents=True, exist_ok=True)
et.write(output_path, xml_declaration=True, encoding="utf-8")
