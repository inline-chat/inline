#!/usr/bin/env python3
"""The engine's fling baked as NSScrollView's, against NSScrollView: travel, end, speed error, lift cost."""
import json, sys, statistics as st
touch = json.load(open('results/bake-touch.json'))
free = json.load(open('results/bake-free.json'))
coastfb = json.load(open('results/bake-coastfallback.json'))
def get(runs, sc, s): return next((r for r in runs if r['scenario'] == sc and r['subject'] == s), None)
def travel(r, upto): return sum(d for d, t in zip(r['screenSteps'], r['screenTimes']) if 0 < t <= upto)
def end(r):
    moving = [t for d, t in zip(r['screenSteps'], r['screenTimes']) if t > 0 and abs(d) > 0.5]
    return max(moving) if moving else 0
def speeds(r):
    """(t ms, pt/s) per captured frame from the lift, capture doubles halved."""
    d = [x for x in r['screenSteps']]; t = r['screenTimes']; out = []
    for i in range(len(d)):
        around = [abs(d[j]) for j in range(max(0, i - 2), min(len(d), i + 3)) if j != i and abs(d[j]) > 0.25]
        e = st.median(around) if around else 0
        k = 2 if e > 3 and abs(abs(d[i]) - 2 * e) < 0.3 * e else 1
        out.append((t[i], abs(d[i]) / k * 75))
    return out
def speed_error(a, ref, upto=300):
    """Worst |speed − reference speed| over 30–upto ms (pt/s), and as a share of the reference's peak there."""
    ra = [(t, v) for t, v in speeds(ref) if 0 < t <= upto + 20]
    if len(ra) < 3: return 0, 0
    def at(t):
        for (t0, v0), (t1, v1) in zip(ra, ra[1:]):
            if t0 <= t <= t1: return v0 + (v1 - v0) * (t - t0) / max(1e-6, t1 - t0)
        return None
    worst = 0
    for t, v in speeds(a):
        if 30 <= t <= upto:
            r = at(t)
            if r is not None: worst = max(worst, abs(v - r))
    peak = max(v for t, v in ra if 30 <= t <= upto) if any(30 <= t <= upto for t, _ in ra) else 1
    return worst, worst / max(1, peak)
def table(runs, title, subjects, names, scenarios):
    print(f"\n{title}\n")
    print("| case | " + " | ".join(f"{names[s]}: 100 / 200 / 500 ms / total (pt), ends (ms)" for s in subjects) + " | worst speed error vs NSScrollView over 300 ms (pt/s, share of its peak): " + ", ".join(names[s] for s in subjects[1:]) + " |")
    print("|---|" + "---|" * len(subjects) + "---|")
    for sc in scenarios:
        rs = {s: get(runs, sc, s) for s in subjects}
        if not rs.get('nsscroll'): continue
        cells = []
        for s in subjects:
            r = rs[s]
            cells.append(f"{travel(r,100):,.0f} / {travel(r,200):,.0f} / {travel(r,500):,.0f} / {travel(r,1e9):,.0f}, {end(r):.0f}" if r else "–")
        errs = []
        for s in subjects[1:]:
            if rs[s]: w, f = speed_error(rs[s], rs['nsscroll']); errs.append(f"{w:,.0f} ({f*100:.0f}%)")
        print(f"| {sc.replace('bake ', '')} | " + " | ".join(cells) + " | " + ", ".join(errs) + " |")
names = {'nsscroll': 'NSScrollView', 'engine-bake': 'bake', 'engine-brake-off': "today's flight", 'engine-coast': 'coaster fallback'}
gest = [f"bake gesture {i}" for i in range(13)]
synth = [f"bake synthetic {v}" for v in (2000, 5000, 10000, 20000)]
# merge the coaster fallback into the touch runs for the table
touch_all = touch + coastfb
table(touch_all, "Mo's 13 gestures, each ended by the touch that really ended it (its next flick), rows 1 ms",
      ['nsscroll', 'engine-bake', 'engine-brake-off', 'engine-coast'], names, gest)
table(free, "The same gestures with no touch at the stream's end (the bake runs its whole path), and natural-decay synthetic streams",
      ['nsscroll', 'engine-bake'], names, gest + synth)
# summary ratios
def ratios(runs, s, sc_list, upto):
    out = []
    for sc in sc_list:
        a, b = get(runs, sc, s), get(runs, sc, 'nsscroll')
        if a and b and abs(travel(b, upto)) > 50: out.append(abs(travel(a, upto)) / abs(travel(b, upto)))
    return out
print()
for s in ('engine-bake', 'engine-brake-off', 'engine-coast'):
    for upto, label in ((100, '100 ms'), (200, '200 ms'), (500, '500 ms'), (1e9, 'total')):
        v = ratios(touch_all, s, gest, upto)
        if v: print(f"{names[s]:18} {label:6} travel ÷ NSScrollView's: median {st.median(v):.2f}, {min(v):.2f}–{max(v):.2f}; within 10%: {sum(abs(x-1)<=0.1 for x in v)}/{len(v)}")
errs = [speed_error(get(touch, sc, 'engine-bake'), get(touch, sc, 'nsscroll'))[1] for sc in gest if get(touch, sc, 'engine-bake')]
print(f"bake: worst speed error over the first 300 ms, share of NSScrollView's peak: median {st.median(errs)*100:.0f}%, worst {max(errs)*100:.0f}%")
print("\nLift cost (main thread): one bake (bake) against bake + steer (today's flight)")
for s in ('engine-bake', 'engine-brake-off'):
    rs = [get(touch, sc, s) for sc in gest + synth]; rs = [r for r in rs if r]
    bake = [r['extra'].get('bakeMs', 0) for r in rs]; steer = [r['extra'].get('steerMs', 0) for r in rs if r['extra'].get('steers', 0) > 0]
    busy = [r['extra'].get('liftBusySum', 0) for r in rs]; bmax = [r['extra'].get('liftBusyMax', 0) for r in rs]
    print(f"{names[s]:16} bake at the lift {st.median(bake):.2f} ms (worst {max(bake):.2f}); steer {st.median(steer) if steer else 0:.2f} ms (worst {max(steer) if steer else 0:.2f}, in {len(steer)} of {len(rs)} flings); main thread in the 5 frames from the lift: {st.median(busy):.1f} ms in all (median), worst frame {st.median(bmax):.1f} ms (median), {max(bmax):.1f} at worst")
