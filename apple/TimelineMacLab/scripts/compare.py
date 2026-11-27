import json, sys, math
# Native vs engine for the same script over HID: displacement after the last move event, sampled at fixed times.
def load(path):
    d = json.load(open(path))
    ins = d['inputs']; ss = [s for s in d['samples'] if 'origin' in s['values']]
    moves = [i for i in ins if i['dy'] != 0 and 'notch' not in i['label']] or ins
    t0 = moves[-1]['t'] if moves else ins[0]['t']
    start = ss[0]['values']['origin']
    return d, ins, ss, t0, start
def at(ss, t, start):
    c = [s for s in ss if s['t'] <= t]
    return (start - c[-1]['values']['origin']) if c else 0.0
rows = []
for name in sys.argv[1:]:
    try:
        dn, insn, ssn, t0n, sn = load(f'results/native.{name}.hid.json')
        de, inse, sse, t0e, se = load(f'results/engine.{name}.hid.json')
    except FileNotFoundError as e:
        print(name, 'missing', e); continue
    grid = [x / 1000 for x in range(-100, 1500, 10)]
    diffs = []
    for g in grid:
        a = at(ssn, t0n + g, sn); b = at(sse, t0e + g, se)
        diffs.append(b - a)
    endn = at(ssn, ssn[-1]['t'], sn); ende = at(sse, sse[-1]['t'], se)
    def stop(ss, t0, start):
        final = start - ss[-1]['values']['origin']
        for s in ss:
            if s['t'] >= t0 and abs((start - s['values']['origin']) - final) < 0.5: return (s['t'] - t0) * 1000
        return float('nan')
    rms = math.sqrt(sum(x * x for x in diffs) / len(diffs))
    peak_n = max((at(ssn, s['t'], sn) for s in ssn), key=abs, default=0)
    print(f"{name:16s} final native={endn:8.1f} engine={ende:8.1f} ({(ende/endn-1)*100 if endn else 0:+5.1f}%)  stop native={stop(ssn,t0n,sn):5.0f}ms engine={stop(sse,t0e,se):5.0f}ms  rms={rms:6.1f} worst={max(diffs,key=abs):7.1f}")
