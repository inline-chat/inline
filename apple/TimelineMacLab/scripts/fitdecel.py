import json, math, itertools
# Fits NSScrollView's own deceleration: v(0) = a*vin (+ jump j pt at release), dv/dt = -v/tau - c, stop under vmin.
names = ['v4', 'v8', 'v16', 'v32', 'v64', 'v16at60', 'middleNoMomentum']
data = []
for name in names:
    d = json.load(open(f'results/native.{name}.hid.json'))
    ins = d['inputs']; ss = [s for s in d['samples'] if 'afterEvent' not in s['values']]
    moves = [i for i in ins if i['label'] in ('g', 'g.began')]
    tlast = moves[-1]['t']
    vin = moves[-1]['dy'] / (moves[-1]['t'] - moves[-2]['t'])
    total_in = sum(i['dy'] for i in ins)
    start = d['notes']['start']
    pts = [(s['t'] - tlast, start - s['values']['origin'] - total_in) for s in ss if s['t'] - tlast >= 0.03]
    data.append((name, vin, pts))

def sim(vin, a, tau, c, vmin, j, ts):
    out = []; p = j; v = a * vin; t = 0.0; dt = 0.001; i = 0
    while i < len(ts):
        while t + dt <= ts[i]:
            if v > vmin:
                v = v - (v / tau + c) * dt
                if v < vmin: v = 0
                p += v * dt
            t += dt
        out.append(p); i += 1
    return out

def err(params):
    a, tau, c, vmin, j = params
    e = 0; n = 0; worst = 0
    for name, vin, pts in data:
        ts = [t for t, _ in pts]; sim_p = sim(vin, a, tau, c, vmin, j, ts)
        for (t, v), s in zip(pts, sim_p):
            e += (v - s) ** 2; n += 1; worst = max(worst, abs(v - s))
    return math.sqrt(e / n), worst

best = None
for a in [1.0, 1.1, 1.2, 1.3]:
    for tau in [0.2, 0.3, 0.4, 0.6]:
        for c in [0, 500, 1000, 2000]:
            for vmin in [20, 60]:
                for j in [0, 30]:
                    r = err((a, tau, c, vmin, j))
                    if best is None or r[0] < best[0][0]: best = (r, (a, tau, c, vmin, j))
print('coarse', best)
params = list(best[1]); steps = [0.05, 0.05, 200, 20, 10]
for _ in range(6):
    improved = True
    while improved:
        improved = False
        for k in range(5):
            for sgn in (-1, 1):
                trial = params[:]; trial[k] = max(0.0001, trial[k] + sgn * steps[k])
                r = err(trial)
                if r[0] < best[0][0]: best = (r, tuple(trial)); params = trial; improved = True
    steps = [s / 2 for s in steps]
print('fit rms/worst', best[0], 'a,tau,c,vmin,jump', [round(x, 4) for x in best[1]])
a, tau, c, vmin, j = best[1]
for name, vin, pts in data:
    ts = [t for t, _ in pts]; s = sim(vin, a, tau, c, vmin, j, ts)
    worst = max(abs(v - x) for (t, v), x in zip(pts, s))
    print(f"  {name:16s} vin={vin:6.0f} travel native={pts[-1][1]:7.1f} model={s[-1]:7.1f} worst={worst:5.1f}")
