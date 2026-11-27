#!/usr/bin/env python3
"""NSScrollView's fling on Mo's recorded gestures (HID replays), against the engine's two modes; fit of its curve.

usage: scripts/flingfit.py results/hid-gestures.json results/gestures-110.jsonl [results/calc.json]
"""
import json, math, sys, statistics as st

runs = json.load(open(sys.argv[1]))
recs = [json.loads(l) for l in open(sys.argv[2]) if l.strip()]
calc = json.load(open(sys.argv[3])) if len(sys.argv) > 3 else None

def clean(r):
    m = r.get('momentumSamples', [])
    if len(m) < 12 or len(r.get('lastTracked', [])) < 3: return False
    return max(b[0] - a[0] for a, b in zip(m, m[1:])) < 0.03

gest = [(i, r) for i, r in enumerate(recs) if clean(r)]
originals = [k for k, (line, _) in enumerate(gest) if line < 72]

def travel(run, upto):
    return sum(d for d, t in zip(run['screenSteps'], run['screenTimes']) if 0 < t <= upto)

def finger_velocities(g):
    tr = sorted(g['lastTracked'], key=lambda x: -x[0])  # oldest first: [seconds before lift, delta]
    times = [-x[0] for x in tr]
    deltas = [x[1] for x in tr]
    out = {}
    # last event over the interval to the previous one
    if len(tr) >= 2:
        dt = max(1e-3, times[-1] - times[-2]); out['last'] = deltas[-1] / dt
    for w in (0.03, 0.05, 0.08):
        sel = [(t, d) for t, d in zip(times, deltas) if t >= -w]
        if len(sel) >= 2:
            span = max(1e-3, sel[-1][0] - sel[0][0])
            out[f'win{int(w*1000)}'] = sum(d for _, d in sel[1:]) / span
    out['momentum'] = g['momentumSamples'][0][1] * 60
    return out

def calc_travel(v, t):
    """AppKit's calculator travel at time t for speed |v| (interpolated in log speed)."""
    s = abs(v)
    if s < 100: return 0
    curves = calc
    lo = max([c for c in curves if c['velocity'] <= s], key=lambda c: c['velocity'], default=curves[0])
    hi = min([c for c in curves if c['velocity'] >= s], key=lambda c: c['velocity'], default=curves[-1])
    def at(c):
        i = min(len(c['positions']) - 1, int(t / c['interval']))
        return c['positions'][i]
    if hi['velocity'] == lo['velocity']: x = at(lo)
    else:
        f = (math.log(s) - math.log(lo['velocity'])) / (math.log(hi['velocity']) - math.log(lo['velocity']))
        x = at(lo) + (at(hi) - at(lo)) * f
    return math.copysign(x, v)

rows = []
for k in originals:
    line, g = gest[k]
    by = {r['subject']: r for r in runs if r['scenario'] == f'gesture {k}'}
    ns, fl, co = by.get('nsscroll'), by.get('engine-flight'), by.get('engine-coast')
    if not ns: continue
    cut = g['momentumFirstDelay'] + g['momentumSamples'][-1][0] + 1 / 60
    stream = sum(x[1] for x in g['momentumSamples'])
    # NSScrollView's speed per frame (pt/s) after the hand-over, for an exponential fit v(t) = v0 exp(-t/tau).
    pts = [(t / 1000, abs(d) / (1 / 75)) for d, t in zip(ns['screenSteps'], ns['screenTimes']) if 40 < t < cut * 1000 - 20 and abs(d) > 2]
    tau = v0 = float('nan')
    if len(pts) >= 6:
        xs = [p[0] for p in pts]; ys = [math.log(p[1]) for p in pts]
        mx, my = st.mean(xs), st.mean(ys)
        slope = sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / sum((x - mx) ** 2 for x in xs)
        tau = -1 / slope if slope < 0 else float('inf'); v0 = math.exp(my - slope * mx)
    fv = finger_velocities(g)
    rows.append(dict(k=k, cut=cut, stream=stream, fv=fv, tau=tau, v0=v0,
                     ns=[travel(ns, 200), travel(ns, 500), travel(ns, 1e9)],
                     fl=[travel(fl, 200), travel(fl, 500), travel(fl, 1e9)] if fl else None,
                     co=[travel(co, 200), travel(co, 500), travel(co, 1e9)] if co else None))

print("| gesture | finger speed, last 50 ms (pt/s) | momentum cut (s) | NSScrollView 200 / 500 ms / total (pt) | render-server engine | coaster | NSScrollView fit v0 (pt/s), tau (s) |")
print("|---|---|---|---|---|---|---|")
for r in rows:
    f = lambda a: f"{a[0]:.0f} / {a[1]:.0f} / {a[2]:.0f}" if a else "–"
    print(f"| {r['k']} | {r['fv'].get('win50', float('nan')):.0f} | {r['cut']:.2f} | {f(r['ns'])} | {f(r['fl'])} | {f(r['co'])} | {r['v0']:.0f}, {r['tau']:.2f} |")

# Which finger estimate predicts NSScrollView's starting speed?
print()
for key in ('last', 'win30', 'win50', 'win80', 'momentum'):
    ratios = [r['v0'] / abs(r['fv'][key]) for r in rows if key in r['fv'] and abs(r['fv'][key]) > 300 and r['v0'] == r['v0']]
    if ratios:
        print(f"v0 ÷ {key:8}: median {st.median(ratios):.2f}, spread {min(ratios):.2f}–{max(ratios):.2f} (n={len(ratios)})")
taus = [r['tau'] for r in rows if r['tau'] == r['tau'] and r['tau'] < 5]
print(f"tau: median {st.median(taus):.2f} s, {min(taus):.2f}–{max(taus):.2f}")

if calc:
    print("\nAppKit's calculator from a finger estimate × gain, cut at the momentum end, against NSScrollView (travel ratio):")
    best = None
    for key in ('last', 'win30', 'win50', 'win80'):
        for gain in [x / 20 for x in range(10, 41)]:
            errs = []
            for r in rows:
                v = r['fv'].get(key)
                if v is None or abs(r['ns'][2]) < 100: continue
                for idx, T in ((0, 0.2), (1, 0.5), (2, r['cut'])):
                    t = min(T, r['cut'])
                    pred = calc_travel(v * gain, t)
                    meas = r['ns'][idx]
                    if abs(meas) > 50: errs.append(abs(pred / meas - 1))
            if errs:
                score = st.median(errs)
                if best is None or score < best[0]: best = (score, key, gain, max(errs), sum(1 for e in errs if e <= 0.1) / len(errs))
    print(f"best: finger estimate {best[1]} × {best[2]:.2f}: median error {best[0]*100:.0f}%, worst {best[3]*100:.0f}%, within 10%: {best[4]*100:.0f}% of points")

# Closed form to bake: x(t) = v0 * tau * (1 - exp(-t / tau)) for t <= cut (the momentum stream's end), with
# v0 = gain * finger speed and tau = a + b * log10(|v0| / 1000), clamped to [0.1, 0.8] s.
def model(v_finger, gain, a, b, t, cut):
    v0 = gain * v_finger
    tau = min(0.8, max(0.1, a + b * math.log10(max(1, abs(v0)) / 1000)))
    tt = min(t, cut)
    return v0 * tau * (1 - math.exp(-tt / tau))

best = None
for key in ('last', 'win50', 'win80'):
    for gain in [x / 100 for x in range(40, 121, 2)]:
        for a in [x / 100 for x in range(10, 41, 2)]:
            for b in [x / 100 for x in range(0, 31, 2)]:
                errs = []
                for r in rows:
                    v = r['fv'].get(key)
                    if v is None: continue
                    for idx, T in ((0, 0.2), (1, 0.5), (2, 9.0)):
                        meas = r['ns'][idx]
                        if abs(meas) < 50: continue
                        errs.append(abs(model(v, gain, a, b, T, r['cut']) / meas - 1))
                if not errs: continue
                score = (st.median(errs), sum(e > 0.1 for e in errs))
                if best is None or score < best[0]: best = (score, key, gain, a, b, errs)
(score, key, gain, a, b, errs) = best
print(f"\nclosed form: v0 = {gain:.2f} × finger speed ({key}), tau = {a:.2f} + {b:.2f}·log10(v0/1000) s (0.1–0.8), cut at the momentum end")
print(f"  error against NSScrollView: median {score[0]*100:.0f}%, {sum(e <= 0.1 for e in errs)}/{len(errs)} points within 10%, worst {max(errs)*100:.0f}%")
print("| gesture | NSScrollView 200 / 500 / total | closed form 200 / 500 / total |")
print("|---|---|---|")
for r in rows:
    v = r['fv'][key]
    pred = [model(v, gain, a, b, T, r['cut']) for T in (0.2, 0.5, 9.0)]
    print(f"| {r['k']} | {r['ns'][0]:.0f} / {r['ns'][1]:.0f} / {r['ns'][2]:.0f} | {pred[0]:.0f} / {pred[1]:.0f} / {pred[2]:.0f} |")
