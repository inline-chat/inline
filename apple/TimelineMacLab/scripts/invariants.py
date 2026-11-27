import json, sys
# Checks the invariants each engine scenario is about. Prints one line per check.
def load(n):
    return json.load(open(f'results/engine.{n}.json'))
def vals(d, k):
    return [(s['t'], s['values'][k], s['values']) for s in d['samples'] if k in s['values']]
def actions(d):
    return sorted((float(k.split('.',1)[1]), v) for k, v in d['texts'].items() if k.startswith('action.'))

def content_y(d):
    # tracked row's content coordinate (screen y + presented scroll position): only the scroll may change screen y
    out = []
    for s in d['samples']:
        v = s['values']
        if 'tracked' in v: out.append((s['t'], v['tracked'] + v['origin'], v))
    return out

def anchor(name):
    d = load(name)
    cy = content_y(d)
    if not cy: print(name, 'tracked row never placed'); return
    base = cy[0][1]
    worst = max(cy, key=lambda x: abs(x[1] - base))
    jumps = [abs(b[1] - a[1]) for a, b in zip(cy, cy[1:])]
    gaps = [s['values'].get('gap', 0) for s in d['samples']]
    print(f"{name}: tracked row content-y drift max {abs(worst[1]-base):.2f} pt at t={worst[0]:.3f}; largest frame-to-frame jump {max(jumps):.2f} pt; samples {len(cy)}; max blank strip {max(gaps):.1f} pt")

def screen_still(name):
    d = load(name)
    tr = [(s['t'], s['values']['tracked']) for s in d['samples'] if 'tracked' in s['values']]
    base = tr[0][1]
    worst = max(tr, key=lambda x: abs(x[1] - base))
    print(f"{name}: tracked row screen-y drift max {abs(worst[1]-base):.2f} pt (t={worst[0]:.3f}) over {len(tr)} samples; actions {[a[1] for a in actions(d)]}")

def pinned(name):
    d = load(name)
    acts = actions(d)
    rest_err = []
    gap_dev = []
    prev = None
    for s in d['samples']:
        v = s['values']
        if 'newestBottom' not in v: continue
        # 'at rest' = no action within 0.45 s before
        recent = [a for a in acts if 0 <= s['t'] - a[0] < 0.45]
        if not recent:
            rest_err.append(abs(v['newestBottom'] - v['usableBottom']))
        gap_dev.append((s['t'], v['composerTop'] - v['newestBottom']))
    rest = [g for t, g in gap_dev if not [a for a in acts if 0 <= t - a[0] < 0.6]]
    restGap = sorted(rest)[len(rest)//2] if rest else 0
    comp = [(t, g) for t, g in gap_dev if [a for a in acts if a[1].startswith('composer') and 0 <= t - a[0] < 0.6]]
    worst = max(comp, key=lambda x: abs(x[1] - restGap)) if comp else (0, restGap)
    print(f"{name}: at rest newest bottom vs usable bottom max {max(rest_err) if rest_err else -1:.2f} pt ({len(rest_err)} samples); composer-to-newest gap during composer animations deviates max {abs(worst[1]-restGap):.2f} pt (rest gap {restGap:.1f}, {len(comp)} samples)")

def inset_scrolled(name):
    d = load(name)
    acts = actions(d)
    pts = [(s['t'], s['values']['composerTop'] - s['values']['tracked']) for s in d['samples'] if 'tracked' in s['values']]
    base = pts[0][1]
    comp = [(t, g) for t, g in pts if [a for a in acts if a[1].startswith('composer') and 0 <= t - a[0] < 0.6]]
    settled = [g for t, g in pts if not [a for a in acts if 0 <= t - a[0] < 0.6]]
    worst = max(comp, key=lambda x: abs(x[1] - base))
    print(f"{name}: reading row to composer top distance deviates max {abs(worst[1]-base):.2f} pt during composer animations ({len(comp)} samples); settled values {sorted(set(round(x,1) for x in settled))[:6]}")

def resize(name):
    d = load(name)
    perf = [s['values']['performMs'] for s in d['samples'] if 'action' in s['values']]
    tr = [(s['t'], s['values']['tracked'], s['values'].get('pinned', 0), s['values']) for s in d['samples'] if 'tracked' in s['values']]
    gaps = [s['values'].get('gap', 0) for s in d['samples']]
    rest = [abs(s['values']['newestBottom'] - s['values']['usableBottom']) for s in d['samples'] if 'newestBottom' in s['values']]
    drift = max(abs(x[1] - tr[0][1]) for x in tr) if tr else -1
    perf_sorted = sorted(perf)
    p = lambda q: perf_sorted[min(len(perf_sorted)-1, int(q*len(perf_sorted)))] if perf_sorted else 0
    print(f"{name}: tracked row screen-y drift max {drift:.1f} pt; newest-bottom error max {max(rest) if rest else -1:.2f}; blank strip max {max(gaps):.1f}; perform ms p50 {p(0.5):.2f} p95 {p(0.95):.2f} max {max(perf) if perf else 0:.2f} over {len(perf)} steps")

def perf(name):
    d = load(name)
    gaps = d['frameGaps']
    nominal = sorted(gaps)[len(gaps)//2]
    long = [g for g in gaps if g > nominal * 1.5]
    perfms = sorted(s['values']['performMs'] for s in d['samples'] if 'performMs' in s['values'])
    p = lambda q: perfms[min(len(perfms)-1, int(q*len(perfms)))]
    print(f"{name}: frames {len(gaps)} nominal {nominal:.1f} ms, late frames {len(long)} (>{nominal*1.5:.1f} ms: {[round(g) for g in long][:8]}); perform ms p50 {p(0.5):.2f} p95 {p(0.95):.2f} max {perfms[-1]:.2f}; makes {d['notes'].get('makes')} updates {d['notes'].get('updates')}")

anchor('anchorDuringFling')
screen_still('anchorAtRest')
pinned('pinnedLive')
inset_scrolled('insetScrolled')
resize('liveResize'); resize('liveResizePinned')
perf('perfFling'); perf('perfStall'); perf('perfDrag')
