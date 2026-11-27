#!/usr/bin/env python3
"""Brake-to-rows results: blank and frozen frames, travel lost against the unbraked fork, the brake's speed changes."""
import json, sys, statistics as st
runs = json.load(open(sys.argv[1] if len(sys.argv) > 1 else 'results/brake.json'))
def get(cost, k, subj):
    return next((r for r in runs if r['scenario'] == f'gesture{cost}ms {k} rows:ahead' and r['subject'] == subj), None)
def per_refresh(r):
    """Per-refresh steps from the lift (capture doubles halved), with times."""
    d = [abs(x) for x in r['screenSteps']]; t = r['screenTimes']; out = []
    for i in range(len(d)):
        around = [d[j] for j in range(max(0, i - 2), min(len(d), i + 3)) if j != i and d[j] > 0.25]
        e = st.median(around) if around else 0
        k = 2 if e > 3 and abs(d[i] - 2 * e) < 0.3 * e else 1
        out.append((t[i], d[i] / k))
    return out
def worst_change(r, windows=None):
    """Worst relative change of speed between consecutive refreshes above 1,000 pt/s (75 Hz), optionally only in the
    given time windows (ms after the lift)."""
    s = per_refresh(r); worst = 0
    for (t0, a), (t1, b) in zip(s, s[1:]):
        if t1 < 60 or max(a, b) * 75 < 1000 or min(a, b) < 0.25: continue
        if windows and not any(lo <= t1 <= hi for lo, hi in windows): continue
        worst = max(worst, abs(b - a) / max(a, b))
    return worst
for cost in (3, 6):
    print(f"\n### rows {cost} ms, layer text, rows prepared ahead (13 gestures)\n")
    print("| | blank: worst (pt) / frames | frozen frames / longest (ms) | travel ÷ unbraked flight (median, worst) | brakes (gestures braked) | worst speed change between frames: in the 120 ms after a brake / anywhere |")
    print("|---|---|---|---|---|---|")
    for subj, name in (('engine-brake-off', 'flight, no brake'), ('engine-brake', 'flight, brake to rows'), ('engine-coast', 'coaster')):
        rs = [get(cost, k, subj) for k in range(13)]
        rs = [r for r in rs if r]
        ratios = []
        for k in range(13):
            r, base = get(cost, k, subj), get(cost, k, 'engine-brake-off')
            if r and base and abs(base['travel']) > 100: ratios.append(abs(r['travel']) / abs(base['travel']))
        brakes = sum(len(r.get('brakeTimes', [])) for r in rs)
        braked = sum(1 for r in rs if r.get('brakeTimes'))
        after = [worst_change(r, [(b - 20, b + 120) for b in r.get('brakeTimes', [])]) for r in rs if r.get('brakeTimes')]
        anywhere = [worst_change(r) for r in rs]
        print(f"| {name} | {max(r['screenBlank'] for r in rs):.0f} / {sum(r['screenBlankFrames'] for r in rs)} | {sum(r['frozenFrames'] for r in rs)} / {max(r['longestFreeze'] for r in rs):.0f} | {st.median(ratios):.2f}, {min(ratios):.2f} | {brakes} ({braked}) | {(max(after) if after else 0)*100:.0f}% / median {st.median(anywhere)*100:.0f}%, worst {max(anywhere)*100:.0f}% |")
    print("\nper gesture, brake to rows: travel ÷ unbraked, blank frames unbraked → braked, brakes")
    line = []
    for k in range(13):
        r, base = get(cost, k, 'engine-brake'), get(cost, k, 'engine-brake-off')
        if r and base:
            line.append(f"{k}: {abs(r['travel'])/max(1,abs(base['travel'])):.2f}, {base['screenBlankFrames']}→{r['screenBlankFrames']}, {len(r.get('brakeTimes', []))}")
    print("; ".join(line))
