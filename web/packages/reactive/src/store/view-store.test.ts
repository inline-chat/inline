import { rowKey } from "@inline/core-protocol"
import { describe, expect, it } from "vitest"
import { computed, effect } from "../signals"
import { echoRow, message, sendText } from "../testing/rows"
import { keyOf, makePatch } from "../testing/scripted-endpoint"
import { ViewStore } from "./view-store"

const upsert = (row: ReturnType<typeof message>) => ({ op: "upsert" as const, row })

describe("rows", () => {
  it("reads rows by kind and ID, untracked reads create no signal", () => {
    const store = new ViewStore()
    const row = message(1, 1)
    store.applyPatch(makePatch(0, { rows: [upsert(row)] }))
    expect(store.row("message", row.id).get()).toBe(row)
    expect(store.row("message", row.id).peek()).toBe(row)
    expect(store.peekRow(keyOf(row))).toBe(row)
    expect(store.row("message", "nope").get()).toBeUndefined()
    expect(store.stats().signals).toBe(0)
  })

  it("creates a row signal when something observes it and releases it when nothing does", () => {
    const store = new ViewStore()
    const row = message(1, 1)
    store.applyPatch(makePatch(0, { rows: [upsert(row)] }))
    const seen: (string | undefined)[] = []
    const dispose = effect(() => {
      seen.push(store.row("message", row.id).get()?.text)
    })
    expect(store.stats().signals).toBe(1)
    store.applyPatch(makePatch(1, { rows: [upsert({ ...row, text: "edited" })] }))
    expect(seen).toEqual(["message 1", "edited"])
    dispose()
    store.sweep()
    expect(store.stats().signals).toBe(0)
    // A handle taken before the sweep still reads the current row.
    const handle = store.row("message", row.id)
    store.applyPatch(makePatch(2, { rows: [upsert({ ...row, text: "again" })] }))
    expect(handle.get()?.text).toBe("again")
  })

  it("sweeps on its own once unobserved signals pile up", () => {
    const store = new ViewStore({ sweepThreshold: 8 })
    const rows = Array.from({ length: 20 }, (_, i) => message(1, i + 1))
    store.applyPatch(makePatch(0, { rows: rows.map(upsert) }))
    for (const row of rows) {
      effect(() => {
        store.row("message", row.id).get()
      })()
    }
    expect(store.stats().signals).toBe(20)
    store.applyPatch(makePatch(1))
    expect(store.stats().signals).toBe(0)
  })

  it("keeps the identity of an unchanged row and notifies nobody", () => {
    const store = new ViewStore()
    const row = message(1, 1)
    store.applyPatch(makePatch(0, { rows: [upsert(row)] }))
    let runs = 0
    effect(() => {
      store.row("message", row.id).get()
      runs += 1
    })
    store.applyPatch(makePatch(1, { rows: [upsert({ ...row })] }))
    expect(store.row("message", row.id).peek()).toBe(row)
    expect(runs).toBe(1)
  })

  it("notifies only the observers of the row that changed", () => {
    const store = new ViewStore()
    const a = message(1, 1)
    const b = message(1, 2)
    store.applyPatch(makePatch(0, { rows: [upsert(a), upsert(b)] }))
    const runs = { a: 0, b: 0 }
    effect(() => {
      store.row("message", a.id).get()
      runs.a += 1
    })
    effect(() => {
      store.row("message", b.id).get()
      runs.b += 1
    })
    store.applyPatch(makePatch(1, { rows: [upsert({ ...b, text: "changed" })] }))
    expect(runs).toEqual({ a: 1, b: 2 })
  })

  it("removes rows", () => {
    const store = new ViewStore()
    const row = message(1, 1)
    store.applyPatch(makePatch(0, { rows: [upsert(row)] }))
    const seen: unknown[] = []
    effect(() => {
      seen.push(store.row("message", row.id).get())
    })
    store.applyPatch(makePatch(1, { rows: [{ op: "remove", kind: "message", id: row.id }] }))
    expect(seen).toEqual([row, undefined])
  })
})

describe("lists and resources", () => {
  it("holds one signal of keys per subscription, replaced and spliced", () => {
    const store = new ViewStore()
    store.ensureSub(1)
    const k = (n: number) => keyOf(message(1, n))
    store.applyPatch(makePatch(0, { lists: [{ sub: 1, op: "replace", keys: [k(1), k(2)] }] }))
    expect(store.list(1).get()).toEqual([k(1), k(2)])
    store.applyPatch(makePatch(1, { lists: [{ sub: 1, op: "splice", index: 2, remove: 0, insert: [k(3)] }] }))
    expect(store.list(1).get()).toEqual([k(1), k(2), k(3)])
    store.applyPatch(makePatch(2, { lists: [{ sub: 1, op: "splice", index: 0, remove: 1, insert: [] }] }))
    expect(store.list(1).get()).toEqual([k(2), k(3)])
  })

  it("keeps list identity when a replace carries the same keys", () => {
    const store = new ViewStore()
    store.ensureSub(1)
    const keys = [keyOf(message(1, 1))]
    store.applyPatch(makePatch(0, { lists: [{ sub: 1, op: "replace", keys }] }))
    const first = store.list(1).get()
    let runs = 0
    effect(() => {
      store.list(1).get()
      runs += 1
    })
    store.applyPatch(makePatch(1, { lists: [{ sub: 1, op: "replace", keys: [...keys] }] }))
    expect(store.list(1).get()).toBe(first)
    expect(runs).toBe(1)
  })

  it("does not touch the list when a row changes", () => {
    const store = new ViewStore()
    store.ensureSub(1)
    const row = message(1, 1)
    store.applyPatch(makePatch(0, { rows: [upsert(row)], lists: [{ sub: 1, op: "replace", keys: [keyOf(row)] }] }))
    let listRuns = 0
    effect(() => {
      store.list(1).get()
      listRuns += 1
    })
    store.applyPatch(makePatch(1, { rows: [upsert({ ...row, text: "edit" })] }))
    expect(listRuns).toBe(1)
  })

  it("holds a resource per subscription and keeps an equal one", () => {
    const store = new ViewStore()
    store.ensureSub(1)
    const value = {
      kind: "window" as const,
      hasOlder: true,
      hasNewer: false,
      atLatest: true,
      loading: "none" as const,
    }
    store.applyPatch(makePatch(0, { resources: [{ sub: 1, value }] }))
    expect(store.resource(1).get()).toBe(value)
    store.applyPatch(makePatch(1, { resources: [{ sub: 1, value: { ...value } }] }))
    expect(store.resource(1).get()).toBe(value)
    store.applyPatch(makePatch(2, { resources: [{ sub: 1, value: { ...value, loading: "older" } }] }))
    expect(store.resource(1).get()).toMatchObject({ loading: "older" })
  })

  it("ignores list and resource changes for subscriptions it does not hold", () => {
    const store = new ViewStore()
    const result = store.applyPatch(
      makePatch(0, { lists: [{ sub: 9, op: "replace", keys: [keyOf(message(1, 1))] }] }),
    )
    expect(result.ok).toBe(true)
    expect(store.hasSub(9)).toBe(false)
  })
})

describe("applyPatch", () => {
  it("refuses a patch whose base is not the current revision and applies nothing", () => {
    const store = new ViewStore()
    store.applyPatch(makePatch(0, { revision: 5 }))
    const row = message(1, 1)
    const result = store.applyPatch(makePatch(4, { revision: 6, rows: [upsert(row)] }))
    expect(result).toEqual({ ok: false, reason: "gap", revision: 5, base: 4 })
    expect(store.peekRow(keyOf(row))).toBeUndefined()
    expect(store.revision.peek()).toBe(5)
  })

  it("installs a whole patch in one batch: observers never see half of it", () => {
    const store = new ViewStore()
    store.ensureSub(1)
    const row = message(1, 1)
    const seen: string[] = []
    effect(() => {
      const keys = store.list(1).get()
      const rows = keys.map((key) => {
        const row = store.rowByKey(key).get()
        return row?.kind === "message" ? row.text : "MISSING"
      })
      seen.push(`${store.revision.get()}:${rows.join(",")}`)
    })
    store.applyPatch(
      makePatch(0, { rows: [upsert(row)], lists: [{ sub: 1, op: "replace", keys: [keyOf(row)] }] }),
    )
    expect(seen).toEqual(["0:", "1:message 1"])
  })
})

describe("replaceAll", () => {
  it("replaces rows, lists and resources and takes the snapshot's revision", () => {
    const store = new ViewStore()
    store.ensureSub(1)
    const a = message(1, 1)
    const b = message(1, 2)
    store.applyPatch(makePatch(0, { rows: [upsert(a)], lists: [{ sub: 1, op: "replace", keys: [keyOf(a)] }] }))
    const seen: unknown[] = []
    effect(() => {
      seen.push(store.row("message", a.id).get())
    })
    store.replaceAll({ revision: 40, rows: [{ ...b }], lists: [{ sub: 1, keys: [keyOf(b)] }], resources: [] })
    expect(store.revision.peek()).toBe(40)
    expect(store.list(1).get()).toEqual([keyOf(b)])
    expect(seen).toEqual([a, undefined])
    expect(store.applyPatch(makePatch(40)).ok).toBe(true)
  })

  it("keeps the identity of rows the snapshot did not change", () => {
    const store = new ViewStore()
    const a = message(1, 1)
    store.applyPatch(makePatch(0, { rows: [upsert(a)] }))
    store.replaceAll({ revision: 3, rows: [{ ...a }], lists: [], resources: [] })
    expect(store.row("message", a.id).peek()).toBe(a)
  })
})

describe("overlay (local echo)", () => {
  const intent = sendText(1, "42", "hello")
  const echo = echoRow(intent)
  const echoKey = keyOf(echo)

  it("makes a prediction readable in the same task, on top of the core's state", () => {
    const store = new ViewStore()
    store.addOverlay("tx1", [{ row: echo }])
    expect(store.rowByKey(echoKey).peek()).toBe(echo)
    expect(store.hasOverlay(echoKey)).toBe(true)
    expect(store.revision.peek()).toBe(0)
  })

  it("shows a prediction over an existing row and restores the row when dropped", () => {
    const store = new ViewStore()
    const row = message(1, 1)
    store.applyPatch(makePatch(0, { rows: [upsert(row)] }))
    const predicted = { ...row, reactions: [{ emoji: "👍", count: 1, mine: true }] }
    const seen: unknown[] = []
    effect(() => {
      seen.push(store.row("message", row.id).get())
    })
    store.addOverlay("tx1", [{ row: predicted }])
    store.dropOverlay("tx1")
    expect(seen).toEqual([row, predicted, row])
  })

  it("appends a predicted row to the lists it names, after the core's keys", () => {
    const store = new ViewStore()
    store.ensureSub(1)
    store.ensureSub(2)
    const first = message(1, 1)
    store.applyPatch(makePatch(0, { rows: [upsert(first)], lists: [{ sub: 1, op: "replace", keys: [keyOf(first)] }] }))
    store.addOverlay("tx1", [{ row: echo, appendTo: [1] }])
    expect(store.list(1).peek()).toEqual([keyOf(first), echoKey])
    expect(store.list(2).peek()).toEqual([])
  })

  it("drops the prediction in the same batch as the patch that carries its row, keeping identity", () => {
    const store = new ViewStore()
    store.ensureSub(1)
    store.addOverlay("tx1", [{ row: echo, appendTo: [1] }])
    const rowSeen: unknown[] = []
    const listSeen: unknown[] = []
    effect(() => {
      rowSeen.push(store.rowByKey(echoKey).get())
    })
    effect(() => {
      listSeen.push(store.list(1).get())
    })
    // The core commits the same row the UI predicted (same pure function).
    store.applyPatch(
      makePatch(0, {
        rows: [upsert({ ...echo })],
        lists: [{ sub: 1, op: "replace", keys: [echoKey] }],
      }),
    )
    expect(store.hasOverlay(echoKey)).toBe(false)
    expect(store.rowByKey(echoKey).peek()).toBe(echo)
    // Nothing flickered: no observer saw a change.
    expect(rowSeen).toEqual([echo])
    expect(listSeen).toEqual([[echoKey]])
  })

  it("drops the prediction when the patch settles its transaction", () => {
    const store = new ViewStore()
    store.addOverlay("tx1", [{ row: echo }])
    store.applyPatch(makePatch(0, { settled: [{ tx: "tx1", status: "accepted" }] }))
    expect(store.hasOverlay(echoKey)).toBe(false)
    expect(store.rowByKey(echoKey).peek()).toBeUndefined()
  })

  it("removes the prediction on a rejection and delivers the result to the waiter", async () => {
    const store = new ViewStore()
    store.ensureSub(1)
    const waiting = store.waitFor("tx1")
    store.addOverlay("tx1", [{ row: echo, appendTo: [1] }])
    store.applyPatch(makePatch(0, { settled: [{ tx: "tx1", status: "rejected", reason: "storageFull" }] }))
    expect(store.list(1).peek()).toEqual([])
    expect(store.rowByKey(echoKey).peek()).toBeUndefined()
    await expect(waiting).resolves.toEqual({ tx: "tx1", status: "rejected", reason: "storageFull" })
    expect(store.stats().waiting).toBe(0)
  })

  it("replaces a prediction for the same row from a newer intent", () => {
    const store = new ViewStore()
    const row = message(1, 1)
    store.addOverlay("tx1", [{ row: { ...row, text: "first" } }])
    store.addOverlay("tx2", [{ row: { ...row, text: "second" } }])
    store.applyPatch(makePatch(0, { settled: [{ tx: "tx1", status: "accepted" }] }))
    expect(store.row("message", row.id).peek()?.text).toBe("second")
  })

  it("is not part of a resync, except for rows the snapshot carries", () => {
    const store = new ViewStore()
    const other = echoRow(sendText(1, "43", "other"))
    store.addOverlay("tx1", [{ row: echo }])
    store.addOverlay("tx2", [{ row: other }])
    store.replaceAll({ revision: 9, rows: [echo], lists: [], resources: [] })
    expect(store.hasOverlay(echoKey)).toBe(false)
    expect(store.hasOverlay(keyOf(other))).toBe(true)
  })

  it("lets a derived value see the prediction immediately", () => {
    const store = new ViewStore()
    store.ensureSub(1)
    const count = computed(() => store.list(1).get().length)
    expect(count.get()).toBe(0)
    store.addOverlay("tx1", [{ row: echo, appendTo: [1] }])
    expect(count.get()).toBe(1)
  })
})

describe("export and import", () => {
  it("exports chosen subscriptions and the rows they need as plain data, and imports them", () => {
    const store = new ViewStore()
    store.ensureSub(1)
    store.ensureSub(2)
    const a = message(1, 1)
    const b = message(1, 2)
    const c = message(2, 3)
    store.applyPatch(
      makePatch(0, {
        rows: [upsert(a), upsert(b), upsert(c)],
        lists: [
          { sub: 1, op: "replace", keys: [keyOf(a)] },
          { sub: 2, op: "replace", keys: [keyOf(c)] },
        ],
      }),
    )
    store.addOverlay("tx", [{ row: echoRow(sendText(1, "5", "pending")), appendTo: [1] }])
    const data = store.exportSnapshot([1], { expand: (row) => (row.id === a.id ? [keyOf(b)] : []) })
    expect(data.lists).toEqual([{ sub: 1, keys: [keyOf(a)] }])
    expect(data.rows).toEqual([a, b])
    const copy = structuredClone(data)
    expect(copy).toEqual(data)

    const fresh = new ViewStore()
    fresh.importSnapshot(copy, () => 7)
    expect(fresh.list(7).peek()).toEqual([keyOf(a)])
    expect(fresh.peekRow(rowKey("message", b.id))).toEqual(b)
    expect(fresh.revision.peek()).toBe(0)
  })
})

describe("provisional state (boot snapshot)", () => {
  const imported = () => {
    const a = message(1, 1)
    const b = message(1, 2)
    const c = message(1, 3)
    const store = new ViewStore()
    store.importSnapshot(
      structuredClone({
        format: 1 as const,
        revision: 9,
        lists: [{ sub: 1, keys: [keyOf(a), keyOf(b), keyOf(c)], resource: { kind: "window" as const, hasOlder: true, hasNewer: false, atLatest: true, loading: "none" as const } }],
        rows: [a, b, c],
      }),
      () => 5,
    )
    return { store, a, b, c, rows: { a: store.peekRow(keyOf(a))!, b: store.peekRow(keyOf(b))!, c: store.peekRow(keyOf(c))! } }
  }

  it("survives the core's first snapshot when it does not name the list yet", () => {
    const { store, a, rows } = imported()
    expect(store.provisionalSubs.peek()).toEqual(new Set([5]))
    store.replaceAll({ revision: 1, rows: [], lists: [], resources: [] })
    expect(store.list(5).peek()).toHaveLength(3)
    expect(store.peekRow(keyOf(a))).toBe(rows.a)
    expect(store.resource(5).peek()?.kind).toBe("window")
    expect(store.revision.peek()).toBe(1)
  })

  it("keeps the identity of equal rows and of an equal list when the core confirms, and renders nothing", () => {
    const { store, a, b, c, rows } = imported()
    const listBefore = store.list(5).peek()
    let rowRuns = 0
    let listRuns = 0
    effect(() => {
      store.rowByKey(keyOf(a)).get()
      rowRuns += 1
    })
    effect(() => {
      store.list(5).get()
      listRuns += 1
    })
    store.applyPatch(
      makePatch(0, {
        rows: [upsert({ ...a }), upsert({ ...b }), upsert({ ...c })],
        lists: [{ sub: 5, op: "replace", keys: [keyOf(a), keyOf(b), keyOf(c)] }],
      }),
    )
    expect(store.peekRow(keyOf(a))).toBe(rows.a)
    expect(store.list(5).peek()).toBe(listBefore)
    expect(rowRuns).toBe(1)
    expect(listRuns).toBe(1)
    expect(store.provisionalSubs.peek().size).toBe(0)
    expect(store.stats().provisional).toBe(0)
    expect(store.stats().rows).toBe(3)
  })

  it("replaces changed rows and drops rows the core did not publish once every list is confirmed", () => {
    const { store, a, b, c, rows } = imported()
    const d = message(1, 4)
    const edited = { ...b, text: "edited" }
    store.applyPatch(
      makePatch(0, {
        rows: [upsert({ ...a }), upsert(edited), upsert(d)],
        lists: [{ sub: 5, op: "replace", keys: [keyOf(a), keyOf(b), keyOf(d)] }],
      }),
    )
    expect(store.peekRow(keyOf(a))).toBe(rows.a)
    expect(store.peekRow(keyOf(b))).toEqual(edited)
    expect(store.peekRow(keyOf(c))).toBeUndefined()
    expect(store.peekRow(keyOf(d))).toEqual(d)
  })

  it("keeps provisional rows while another provisional list is pending", () => {
    const a = message(1, 1)
    const z = message(2, 9)
    const store = new ViewStore()
    store.importSnapshot({
      format: 1,
      revision: 0,
      lists: [
        { sub: 1, keys: [keyOf(a)] },
        { sub: 2, keys: [keyOf(z)] },
      ],
      rows: [a, z],
    })
    store.applyPatch(makePatch(0, { lists: [{ sub: 1, op: "replace", keys: [] }] }))
    expect(store.peekRow(keyOf(z))).toEqual(z)
    expect(store.provisionalSubs.peek()).toEqual(new Set([2]))
    store.applyPatch(makePatch(1, { lists: [{ sub: 2, op: "splice", index: 0, remove: 0, insert: [keyOf(z)] }] }))
    // A splice on a provisional list applies to what the core believes the UI holds: nothing.
    expect(store.list(2).peek()).toEqual([keyOf(z)])
    expect(store.peekRow(keyOf(z))).toBeUndefined()
  })

  it("drops a provisional row the core removes, and everything on dropProvisional", () => {
    const { store, a, b } = imported()
    store.applyPatch(makePatch(0, { rows: [{ op: "remove", kind: "message", id: a.id }] }))
    expect(store.peekRow(keyOf(a))).toBeUndefined()
    store.dropProvisional()
    expect(store.peekRow(keyOf(b))).toBeUndefined()
    expect(store.list(5).peek()).toEqual([])
    expect(store.resource(5).peek()).toBeUndefined()
    expect(store.provisionalSubs.peek().size).toBe(0)
  })

  it("never shadows a row the core already published, and exports provisional rows", () => {
    const store = new ViewStore()
    const a = message(1, 1)
    store.applyPatch(makePatch(0, { rows: [upsert(a)] }))
    store.importSnapshot({ format: 1, revision: 0, lists: [{ sub: 3, keys: [keyOf(a)] }], rows: [{ ...a, text: "stale" }] })
    expect(store.peekRow(keyOf(a))).toBe(a)
    const b = message(1, 2)
    store.importSnapshot({ format: 1, revision: 0, lists: [{ sub: 4, keys: [keyOf(b)] }], rows: [b] })
    expect(store.exportSnapshot([4]).rows).toEqual([b])
  })
})

describe("bounded export", () => {
  it("exports only the selected part of a list and the rows it needs", () => {
    const store = new ViewStore()
    store.ensureSub(1)
    const rows = Array.from({ length: 10 }, (_, i) => message(1, i + 1))
    store.applyPatch(makePatch(0, { rows: rows.map(upsert), lists: [{ sub: 1, op: "replace", keys: rows.map(keyOf) }] }))
    const data = store.exportSnapshot([1], { select: (_sub, keys) => keys.slice(-3) })
    expect(data.lists[0]!.keys).toEqual(rows.slice(-3).map(keyOf))
    expect(data.rows).toEqual(rows.slice(-3))
  })
})
