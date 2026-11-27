#!/usr/bin/env python3
"""Markdown tables from TimelineScrollLab --compare JSON files: one row per scenario, one column group per subject.

usage: scripts/table.py results/compare-*.json [--metric blank,screenBlank,...]
"""
import json
import sys
from collections import OrderedDict, defaultdict

paths = [a for a in sys.argv[1:] if not a.startswith("--")]
runs = []
for path in paths:
    with open(path) as f:
        runs += json.load(f)

by_scenario = OrderedDict()
subjects = []
for r in runs:
    by_scenario.setdefault(r["scenario"], {})[r["subject"]] = r
    if r["subject"] not in subjects:
        subjects.append(r["subject"])


def cell(r, metric):
    if r is None:
        return "–"
    v = r.get(metric, r.get("extra", {}).get(metric))
    if v is None:
        return "–"
    if isinstance(v, float):
        return f"{v:.0f}" if abs(v) >= 10 else f"{v:.1f}"
    return str(v)


def table(title, metrics, scenarios=None):
    print(f"\n### {title}\n")
    head = "| scenario | " + " | ".join(f"{s}" for s in subjects) + " |"
    print(head)
    print("|" + "---|" * (len(subjects) + 1))
    for name, row in by_scenario.items():
        if scenarios and not any(name.startswith(p) for p in scenarios):
            continue
        cells = []
        for s in subjects:
            r = row.get(s)
            cells.append(" / ".join(cell(r, m) for m in metrics))
        print(f"| {name} | " + " | ".join(cells) + " |")


metric_sets = {
    "screen blank pt / textless rows (screen)": ["screenBlank", "screenTextless"],
    "frozen frames / longest freeze ms / jumps / worst jump pt": ["frozenFrames", "longestFreeze", "jumps", "worstJump"],
    "main thread per frame p50 / p95 / max ms": ["busyP50", "busyP95", "busyMax"],
    "travel after lift / system's travel (pt)": ["travel", "eventTravel"],
}
for title, metrics in metric_sets.items():
    table(title, metrics)

# Gesture summary per subject.
gestures = [r for r in runs if r["scenario"].startswith("gesture")]
if gestures:
    print("\n### Real gestures, per subject\n")
    print("| subject | n | travel / system's (median) | screen blank max | frames with blank | textless max | frames textless | frozen frames (total) | jumps (total) | main p95 (median) |")
    print("|---|---|---|---|---|---|---|---|---|---|")
    per = defaultdict(list)
    for r in gestures:
        per[r["subject"]].append(r)
    for s in subjects:
        rs = per.get(s, [])
        if not rs:
            continue
        ratios = sorted(r["travel"] / r["eventTravel"] for r in rs if abs(r["eventTravel"]) > 50)
        med = ratios[len(ratios) // 2] if ratios else float("nan")
        p95s = sorted(r["busyP95"] for r in rs)
        print(f"| {s} | {len(rs)} | {med:.2f} | {max(r['screenBlank'] for r in rs):.0f} | {sum(r['screenBlankFrames'] for r in rs)} | {max(r['screenTextless'] for r in rs)} | {sum(r['screenTextlessFrames'] for r in rs)} | {sum(r['frozenFrames'] for r in rs)} | {sum(r['jumps'] for r in rs)} | {p95s[len(p95s)//2]:.1f} |")
