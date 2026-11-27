#!/usr/bin/env python3
"""Final head-to-head: the engine (render-server flight, main-thread coaster) against the NSScrollView prototype on
Mo's 13 gestures at 1, 3 and 6 ms rows (layer text, rows planned ahead, a touch at each stream's end).
Usage: scripts/final.py results/final-h2h-1.json [results/final-h2h-2.json …]"""
import json, sys, statistics as st, re

passes = [json.load(open(p)) for p in sys.argv[1:]]
subjects = ['engine-flight', 'engine-coast', 'nsscroll']
names = {'engine-flight': 'engine (flight)', 'engine-coast': 'engine (coaster)', 'nsscroll': 'NSScrollView'}

def key(r):
    m = re.match(r'gesture(\d+(?:\.\d+)?)ms (\d+) rows:(\w+)', r['scenario'])
    return (float(m.group(1)), int(m.group(2))) if m else None

def runs(cost, s):
    out = []
    for p, runs_ in enumerate(passes):
        for r in runs_:
            k = key(r)
            if k and k[0] == cost and r['subject'] == s:
                out.append((p, k[1], r))
    return out

def fmt(v, d=0):
    return f"{v:,.{d}f}"

costs = sorted({key(r)[0] for p in passes for r in p if key(r)})
print(f"passes: {len(passes)}, runs: {sum(len(p) for p in passes)}\n")
print("| rows | list | blank frames (worst pt) | text-less frames | frozen frames (longest ms) | main p95 median / worst p95 / worst frame (ms) | travel ÷ NSScrollView: median (range) | with fingers' | lift frame median / worst (ms) | lift + 5 frames worst (ms) |")
print("|---|---|---|---|---|---|---|---|---|---|")
for cost in costs:
    ref = {(p, g): r for p, g, r in runs(cost, 'nsscroll')}
    for s in subjects:
        rs = runs(cost, s)
        if not rs: continue
        n = len(rs)
        blank = sum(r['screenBlankFrames'] for _, _, r in rs)
        blankpt = max(r['screenBlank'] for _, _, r in rs)
        textless = sum(r['screenTextlessFrames'] for _, _, r in rs)
        frozen = sum(r['frozenFrames'] for _, _, r in rs)
        longest = max(r['longestFreeze'] for _, _, r in rs)
        p95 = [r['busyP95'] for _, _, r in rs]
        worst = max(r['busyMax'] for _, _, r in rs)
        ratios, ratiosAll = [], []
        for p, g, r in rs:
            b = ref.get((p, g))
            if b and abs(b['travel']) > 20:
                ratios.append(r['travel'] / b['travel'])
            if b and abs(b['extra'].get('travelAll', 0)) > 20:
                ratiosAll.append(r['extra'].get('travelAll', 0) / b['extra']['travelAll'])
        lift = [r['extra'].get('liftFrameBusy', 0) for _, _, r in rs]
        liftmax = [r['extra'].get('liftBusyMax', 0) for _, _, r in rs]
        ratio = (f"{st.median(ratios):.2f} ({min(ratios):.2f}–{max(ratios):.2f})" if ratios and s != 'nsscroll' else '1')
        ratioAll = (f"{st.median(ratiosAll):.2f}" if ratiosAll and s != 'nsscroll' else '1')
        print(f"| {fmt(cost)} ms | {names[s]} | {blank} ({fmt(blankpt)}) | {textless} | {frozen} ({fmt(longest)}) | "
              f"{st.median(p95):.1f} / {max(p95):.1f} / {worst:.1f} | {ratio} | {ratioAll} | "
              f"{st.median(lift):.1f} / {max(lift):.1f} | {max(liftmax):.1f} |")
print(f"\n(each cell: {len(passes)} pass(es) × 13 gestures; frames are counted on screen, ScreenCaptureKit)")

# Per gesture travel, first pass, to spot where the ratio moves.
print("\nper gesture travel after the lift (pt), pass medians:")
for cost in costs:
    print(f"\n{fmt(cost)} ms rows")
    print("| gesture | " + " | ".join(names[s] for s in subjects) + " | flight ÷ NS | coaster ÷ NS |")
    print("|---|" + "---|" * (len(subjects) + 2))
    by = {s: {} for s in subjects}
    for s in subjects:
        for p, g, r in runs(cost, s):
            by[s].setdefault(g, []).append(r['travel'])
    for g in sorted(by['nsscroll']):
        vals = {s: st.median(by[s][g]) if g in by[s] else float('nan') for s in subjects}
        ns = vals['nsscroll']
        print(f"| {g} | " + " | ".join(fmt(vals[s]) for s in subjects) +
              f" | {vals['engine-flight'] / ns:.2f} | {vals['engine-coast'] / ns:.2f} |")
