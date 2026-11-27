import json, sys
# Prints a scenario's inputs and origin trajectory compactly.
d = json.load(open(sys.argv[1]))
key = sys.argv[2] if len(sys.argv) > 2 else "origin"
every = int(sys.argv[3]) if len(sys.argv) > 3 else 1
print("notes", d["notes"])
ins = d["inputs"]
print("inputs", len(ins), "first", ins[0] if ins else None, "last", ins[-1] if ins else None)
tot = sum(i["dy"] for i in ins)
print("sum dy", round(tot, 2))
ss = [s for s in d["samples"] if key in s["values"]]
prev = None
rows = []
for i, s in enumerate(ss):
    v = s["values"][key]
    if prev is None or abs(v - prev) > 0.001 or "afterEvent" in s["values"]:
        rows.append((round(s["t"], 4), round(v, 2), "E" if "afterEvent" in s["values"] else ""))
    prev = v
for r in rows[::every]:
    print(*r)
