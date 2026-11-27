import json, sys
# Cumulative input vs displayed displacement over time (positive dy = origin decreases).
d = json.load(open(sys.argv[1]))
key = sys.argv[2] if len(sys.argv) > 2 else "origin"
step = float(sys.argv[3]) if len(sys.argv) > 3 else 0.05
ins = d["inputs"]; ss = [s for s in d["samples"] if key in s["values"]]
start = ss[0]["values"][key]
t = ins[0]["t"] - 0.02
end = ss[-1]["t"]
while t <= end:
    cum = sum(i["dy"] for i in ins if i["t"] <= t)
    shown = [s for s in ss if s["t"] <= t]
    v = shown[-1]["values"][key] if shown else start
    lab = [i["label"] for i in ins if t - step < i["t"] <= t]
    print(f"{t:6.3f} in={cum:7.1f} shown={start - v:7.1f} diff={cum - (start - v):6.1f} {lab[-1] if lab else ''}")
    t += step
