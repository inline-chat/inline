#!/usr/bin/env python3
"""Summarise a timeline journey's results (<label>.jsonl): one block per scenario, the numbers that matter."""
import json
import sys


def frames(f):
    if not isinstance(f, dict):
        return ""
    if "error" in f:
        return f"error {f['error']}"
    parts = [f"{f.get('frames', 0)} frames", f"hitches {f.get('hitches', 0)} (lost {f.get('lostFrames', 0)})",
             f"worst {f.get('worstIntervalMs', 0)} ms", f"perform {f.get('performMs', 0)} ms / {f.get('performs', 0)}",
             f"max {f.get('performMaxMs', 0)} ms", f"rows made {f.get('rowsMade', 0)}", f"cpu {f.get('cpuMs', 0)} ms"]
    if "blankGapMaxPt" in f:
        parts.append(f"blank gap {f['blankGapMaxPt']} pt in {f.get('blankFrames', 0)} frames, edges {f.get('edgeUncoveredMaxPt', 0)} pt")
    if "driftMaxPt" in f:
        parts.append(f"drift max {f['driftMaxPt']} pt, end {f.get('driftEndPt', '?')} pt")
    if "bubbleToRowBottomDriftMaxPt" in f:
        parts.append(f"bubble to row bottom drift max {f['bubbleToRowBottomDriftMaxPt']} pt, inside tracks {f.get('insideTracks', 0)}")
    if "driftError" in f:
        parts.append(f["driftError"])
    return ", ".join(parts)


def main(path):
    for line in open(path):
        r = json.loads(line)
        name = r.get("scenario")
        print(f"\n== {name} (load {r.get('load')}, {r.get('wallMs')} ms)")
        if "error" in r:
            print(f"  ERROR {r['error']}")
        if name == "open":
            for s in r.get("switches", []):
                f = s["frames"]
                print(f"  r{s['round']} {s['peer']}: rows {s['rowsMs']} ms (plans {s.get('planMs', '?')} ms; in the open call: {s['rowsInOpenCall']}), "
                      f"settle {s['settleMs']} ms, empty frames {f.get('emptyFrames')}, stale {f.get('staleFrames')}, "
                      f"hitches {f.get('hitches')} worst {f.get('worstIntervalMs')} ms")
        elif name == "fling":
            for i, s in enumerate(r.get("flings", [])):
                print(f"  {i:2} {'up  ' if s['up'] else 'down'} travel {s['travel']:8} pt {s['ms']:7} ms: {frames(s['frames'])}")
        elif name == "drag":
            for s in r.get("drags", []):
                print(f"  per event {s['perEventMs']}: {frames(s['frames'])}")
        elif name in ("edit", "delete"):
            for c in r.get("cases", []):
                if "error" in c:
                    print(f"  {c['case']}: {c['error']}")
                    continue
                for key in ("grow", "back", "frames"):
                    if key in c:
                        made = f", rows made at once {c['rowsMade']}" if key == "frames" and "rowsMade" in c else ""
                        print(f"  {c['case']} {key}: {frames(c[key])}{made}")
        elif name == "react":
            for c in r.get("cases", []):
                if "error" in c:
                    print(f"  {c['case']}: {c['error']}")
                    continue
                for key in ("add", "remove"):
                    fade = f", reactions opacity from {c.get('addLowestReactionOpacity')}" if key == "add" else ""
                    print(f"  {c['case']} {key}: kept cell {c.get(key + 'KeptCell')}, height {c.get(key + 'HeightDelta')}{fade}: {frames(c[key])}")
        elif name == "appearance":
            for s in r.get("steps", []):
                print(f"  to {s['to']}: settle {s['settleMs']} ms, rows made {s['rowsMade']}: {frames(s['frames'])}")
        elif name == "resize":
            for key in ("atBottom", "reading"):
                if key in r:
                    print(f"  {key}: {frames(r[key])}")
        else:
            for key, value in r.items():
                if key in ("scenario", "load", "wallMs", "certified"):
                    continue
                print(f"  {key}: {frames(value) if isinstance(value, dict) and 'frames' in value else value}")


if __name__ == "__main__":
    main(sys.argv[1])
