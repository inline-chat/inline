/**
 * The contract the rest of web/ relies on. Any implementation behind
 * signals.ts (alien-signals today, perhaps @solidjs/signals later) has to pass
 * this file unchanged. See web/docs/reactivity.md.
 */
import { afterEach, beforeEach, describe, expect, it } from "vitest"
import {
  batch,
  computed,
  effect,
  observedSignal,
  onDispose,
  scope,
  scoped,
  setErrorHandler,
  signal,
  untracked,
  type ErrorHandler,
} from "./signals"

let reported: unknown[] = []
let previousHandler: ErrorHandler | undefined

beforeEach(() => {
  reported = []
  previousHandler = setErrorHandler((error) => reported.push(error))
})

afterEach(() => {
  setErrorHandler(previousHandler)
})

describe("sync reads (the sync lane's promise)", () => {
  it("makes a write readable immediately, with no flush or microtask", () => {
    // Solid 2's core defers writes to a microtask and needs flush() for a
    // synchronous read. Our contract does not: a local echo written in an
    // input handler is readable, and paintable, in the same task.
    const text = signal("a")
    const upper = computed(() => text.get().toUpperCase())
    expect(upper.get()).toBe("A")
    text.set("b")
    expect(text.get()).toBe("b")
    expect(text.peek()).toBe("b")
    expect(upper.get()).toBe("B")
  })

  it("makes a write readable immediately inside a batch, before observers run", () => {
    const count = signal(1)
    const double = computed(() => count.get() * 2)
    const seen: number[] = []
    effect(() => {
      seen.push(double.get())
    })
    batch(() => {
      count.set(5)
      expect(count.get()).toBe(5)
      expect(double.get()).toBe(10)
      expect(seen).toEqual([2])
    })
    expect(seen).toEqual([2, 10])
  })

  it("runs effects synchronously at the end of the write, not on a later turn", () => {
    const value = signal(0)
    const seen: number[] = []
    effect(() => {
      seen.push(value.get())
    })
    value.set(1)
    expect(seen).toEqual([0, 1])
  })
})

describe("glitch-free reads", () => {
  it("never shows a diamond's join a mixed state", () => {
    const source = signal(1)
    const left = computed(() => source.get() + 1)
    const right = computed(() => source.get() * 10)
    const joins: string[] = []
    const join = computed(() => {
      const value = `${left.get()}/${right.get()}`
      joins.push(value)
      return value
    })
    const seen: string[] = []
    effect(() => {
      seen.push(join.get())
    })
    source.set(2)
    source.set(3)
    expect(seen).toEqual(["2/10", "3/20", "4/30"])
    // The join evaluated once per change, never with one side stale.
    expect(joins).toEqual(["2/10", "3/20", "4/30"])
  })

  it("runs an effect once for a diamond, with consistent inputs", () => {
    const a = signal(1)
    const b = computed(() => a.get() * 2)
    const c = computed(() => a.get() * 3)
    const seen: [number, number][] = []
    effect(() => {
      seen.push([b.get(), c.get()])
    })
    a.set(2)
    expect(seen).toEqual([
      [2, 3],
      [4, 6],
    ])
  })
})

describe("lazy computeds", () => {
  it("does not evaluate a computed until it is read", () => {
    const source = signal(1)
    let runs = 0
    const derived = computed(() => {
      runs += 1
      return source.get() + 1
    })
    expect(runs).toBe(0)
    source.set(2)
    source.set(3)
    expect(runs).toBe(0)
    expect(derived.get()).toBe(4)
    expect(runs).toBe(1)
  })

  it("caches until a source changes, and recomputes only when read again", () => {
    const source = signal(1)
    let runs = 0
    const derived = computed(() => {
      runs += 1
      return source.get()
    })
    derived.get()
    derived.get()
    derived.peek()
    expect(runs).toBe(1)
    source.set(2)
    expect(runs).toBe(1)
    expect(derived.peek()).toBe(2)
    expect(runs).toBe(2)
  })

  it("does not recompute a branch that is no longer read", () => {
    const useLeft = signal(true)
    const left = signal(1)
    const right = signal(2)
    let runs = 0
    const pick = computed(() => {
      runs += 1
      return useLeft.get() ? left.get() : right.get()
    })
    effect(() => {
      pick.get()
    })
    useLeft.set(false)
    const before = runs
    left.set(10)
    expect(runs).toBe(before)
  })
})

describe("batching", () => {
  it("notifies once for many writes in a batch", () => {
    const a = signal(1)
    const b = signal(1)
    const sums: number[] = []
    effect(() => {
      sums.push(a.get() + b.get())
    })
    batch(() => {
      a.set(2)
      b.set(3)
      a.set(4)
    })
    expect(sums).toEqual([2, 7])
  })

  it("defers observers to the end of the outermost batch", () => {
    const a = signal(0)
    const seen: number[] = []
    effect(() => {
      seen.push(a.get())
    })
    batch(() => {
      a.set(1)
      batch(() => {
        a.set(2)
      })
      expect(seen).toEqual([0])
      a.set(3)
    })
    expect(seen).toEqual([0, 3])
  })

  it("returns the value of the batched function", () => {
    expect(batch(() => 42)).toBe(42)
  })

  it("still flushes when the batched function throws", () => {
    const a = signal(0)
    const seen: number[] = []
    effect(() => {
      seen.push(a.get())
    })
    expect(() =>
      batch(() => {
        a.set(1)
        throw new Error("boom")
      }),
    ).toThrow("boom")
    expect(seen).toEqual([0, 1])
    a.set(2)
    expect(seen).toEqual([0, 1, 2])
  })
})

describe("equality", () => {
  it("does not notify on a write of the same value", () => {
    const a = signal(1)
    let runs = 0
    effect(() => {
      a.get()
      runs += 1
    })
    a.set(1)
    a.update((n) => n)
    expect(runs).toBe(1)
  })

  it("uses the signal's own equality", () => {
    const row = signal({ id: 1, text: "a" }, { equals: (x, y) => x.id === y.id && x.text === y.text })
    const first = row.peek()
    let runs = 0
    effect(() => {
      row.get()
      runs += 1
    })
    row.set({ id: 1, text: "a" })
    expect(runs).toBe(1)
    expect(row.peek()).toBe(first)
    row.set({ id: 1, text: "b" })
    expect(runs).toBe(2)
  })

  it("keeps a computed's previous value and identity when its equality says equal", () => {
    const ids = signal([1, 2, 3])
    const sameArray = (x: number[], y: number[]) => x.length === y.length && x.every((v, i) => v === y[i])
    const evens = computed(() => ids.get().filter((n) => n % 2 === 0), { equals: sameArray })
    const first = evens.get()
    let runs = 0
    effect(() => {
      evens.get()
      runs += 1
    })
    ids.set([1, 2, 5])
    expect(evens.get()).toBe(first)
    expect(runs).toBe(1)
    ids.set([2, 4])
    expect(evens.get()).toEqual([2, 4])
    expect(runs).toBe(2)
  })

  it("does not re-run observers of a computed whose value did not change", () => {
    const n = signal(1)
    const parity = computed(() => n.get() % 2)
    let runs = 0
    effect(() => {
      parity.get()
      runs += 1
    })
    n.set(3)
    n.set(5)
    expect(runs).toBe(1)
  })
})

describe("untracked", () => {
  it("does not subscribe to reads inside untracked or peek", () => {
    const a = signal(1)
    const b = signal(1)
    let runs = 0
    effect(() => {
      untracked(() => a.get())
      b.peek()
      runs += 1
    })
    a.set(2)
    b.set(2)
    expect(runs).toBe(1)
  })
})

describe("disposal", () => {
  it("stops an effect after dispose and runs its cleanup once", () => {
    const a = signal(0)
    const log: string[] = []
    const dispose = effect(() => {
      const value = a.get()
      log.push(`run ${value}`)
      return () => log.push(`cleanup ${value}`)
    })
    a.set(1)
    dispose()
    a.set(2)
    dispose()
    expect(log).toEqual(["run 0", "cleanup 0", "run 1", "cleanup 1"])
  })

  it("disposes every effect and nested scope of a scope, cleanups in reverse order", () => {
    const a = signal(0)
    const log: string[] = []
    const dispose = scope(() => {
      effect(() => {
        a.get()
        log.push("outer")
        return () => log.push("outer cleanup")
      })
      scope(() => {
        effect(() => {
          a.get()
          log.push("inner")
          return () => log.push("inner cleanup")
        })
      })
    })
    dispose()
    a.set(1)
    expect(log).toEqual(["outer", "inner", "inner cleanup", "outer cleanup"])
  })

  it("disposes effects created by an effect when it re-runs", () => {
    const outer = signal(0)
    const inner = signal(0)
    const log: string[] = []
    effect(() => {
      const o = outer.get()
      effect(() => {
        log.push(`child ${o}:${inner.get()}`)
        return () => log.push(`child cleanup ${o}`)
      })
    })
    outer.set(1)
    inner.set(1)
    expect(log).toEqual(["child 0:0", "child cleanup 0", "child 1:0", "child cleanup 1", "child 1:1"])
  })

  it("returns the value of a scoped function with its disposer", () => {
    const a = signal(0)
    let runs = 0
    const [model, dispose] = scoped(() => {
      effect(() => {
        a.get()
        runs += 1
      })
      return { name: "model" }
    })
    expect(model.name).toBe("model")
    dispose()
    a.set(1)
    expect(runs).toBe(1)
  })

  it("runs onDispose callbacks when their scope is disposed", () => {
    const log: string[] = []
    const dispose = scope(() => {
      onDispose(() => log.push("disposed"))
    })
    expect(log).toEqual([])
    dispose()
    expect(log).toEqual(["disposed"])
  })
})

describe("errors", () => {
  it("reports an effect's error without throwing it into the writer", () => {
    const a = signal(0)
    effect(() => {
      if (a.get() === 1) throw new Error("effect failed")
    })
    expect(() => a.set(1)).not.toThrow()
    expect(reported).toHaveLength(1)
    expect((reported[0] as Error).message).toBe("effect failed")
  })

  it("keeps other effects of the same flush running when one throws", () => {
    const a = signal(0)
    const seen: string[] = []
    effect(() => {
      seen.push(`first ${a.get()}`)
    })
    effect(() => {
      if (a.get() === 1) throw new Error("middle")
      seen.push(`middle ${a.get()}`)
    })
    effect(() => {
      seen.push(`last ${a.get()}`)
    })
    batch(() => a.set(1))
    expect(seen).toEqual(["first 0", "middle 0", "last 0", "first 1", "last 1"])
    a.set(2)
    expect(seen).toEqual(["first 0", "middle 0", "last 0", "first 1", "last 1", "first 2", "middle 2", "last 2"])
  })

  it("keeps a throwing effect subscribed so it recovers on the next change", () => {
    const a = signal(0)
    const seen: number[] = []
    effect(() => {
      const value = a.get()
      if (value === 1) throw new Error("once")
      seen.push(value)
    })
    a.set(1)
    a.set(2)
    expect(seen).toEqual([0, 2])
    expect(reported).toHaveLength(1)
  })

  it("rethrows a computed's error on every read until a source changes", () => {
    const a = signal(0)
    let runs = 0
    const derived = computed(() => {
      runs += 1
      if (a.get() === 1) throw new Error("bad input")
      return a.get() * 2
    })
    expect(derived.get()).toBe(0)
    a.set(1)
    expect(() => derived.get()).toThrow("bad input")
    expect(() => derived.peek()).toThrow("bad input")
    expect(runs).toBe(2)
    a.set(2)
    expect(derived.get()).toBe(4)
  })

  it("reports an error thrown by a cleanup and still disposes", () => {
    const a = signal(0)
    let runs = 0
    const dispose = effect(() => {
      a.get()
      runs += 1
      return () => {
        throw new Error("cleanup failed")
      }
    })
    dispose()
    a.set(1)
    expect(runs).toBe(1)
    expect(reported).toHaveLength(1)
  })
})

describe("observed signals", () => {
  it("reports whether anything observes it", () => {
    const cell = observedSignal(1)
    expect(cell.observed()).toBe(false)
    expect(cell.get()).toBe(1)
    expect(cell.observed()).toBe(false)
    const dispose = effect(() => {
      cell.get()
    })
    expect(cell.observed()).toBe(true)
    dispose()
    expect(cell.observed()).toBe(false)
  })

  it("is observed through a watched computed and released with it", () => {
    const cell = observedSignal(1)
    const derived = computed(() => cell.get() + 1)
    const dispose = effect(() => {
      derived.get()
    })
    expect(cell.observed()).toBe(true)
    cell.set(2)
    expect(derived.peek()).toBe(3)
    dispose()
    expect(cell.observed()).toBe(false)
  })

  it("stays linked to a computed that was evaluated but never watched (known limit)", () => {
    const cell = observedSignal(1)
    const derived = computed(() => cell.get())
    derived.peek()
    expect(cell.observed()).toBe(true)
  })
})
