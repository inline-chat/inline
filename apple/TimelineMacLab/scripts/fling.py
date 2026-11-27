import json, sys, math
# After-release trajectory of a native fling: distance, duration, and the per-ms decay that fits it.
for name in sys.argv[1:]:
    d = json.load(open(f'results/native.{name}.hid.json'))
    ins = d['inputs']; ss = [s for s in d['samples'] if 'afterEvent' not in s['values']]
    tend = [i['t'] for i in ins if i['label'].endswith('.ended')][0]
    g = sum(i['dy'] for i in ins)
    start = d['notes']['start']
    pts = [(s['t'] - tend, start - s['values']['origin'] - g) for s in ss]
    after = [(t, v) for t, v in pts if t >= 0]
    total = after[-1][1]
    stop = next(t for t, v in after if abs(v - total) < 0.5)
    # velocity just after release from first 40ms
    seg = [(t, v) for t, v in after if t <= 0.06]
    v0 = (seg[-1][1] - seg[0][1]) / (seg[-1][0] - seg[0][0]) if len(seg) > 1 else 0
    # fit tau from remaining distance: rem(t) = total - v(t); exponential => rem = A e^{-t/tau}
    fit = [(t, total - v) for t, v in after if 0.03 < t < stop * 0.8 and total - v > 2]
    if len(fit) > 3:
        xs = [t for t, r in fit]; ys = [math.log(r) for t, r in fit]
        n = len(xs); mx = sum(xs) / n; my = sum(ys) / n
        slope = sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / sum((x - mx) ** 2 for x in xs)
        tau = -1 / slope
    else:
        tau = float('nan')
    ev = [i for i in ins if i['label'] in ('g', 'g.began')]
    vin = ev[-1]['dy'] / (ev[-1]['t'] - ev[-2]['t']) if len(ev) > 1 else 0
    print(f"{name:10s} inVel={vin:7.0f} relVel0={v0:7.0f} travel={total:7.1f} stop={stop*1000:5.0f}ms tau={tau*1000:5.0f}ms travel/inVel={total/vin if vin else 0:.3f}")
