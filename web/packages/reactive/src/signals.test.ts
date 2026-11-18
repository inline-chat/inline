import { describe, expect, it } from "vitest"
import { batch, computed, effect, scope, signal, untracked } from "./signals"

describe("signals", () => {
  it("reads, writes and derives", () => {
    const count = signal(1)
    const double = computed(() => count.get() * 2)
    expect(double.get()).toBe(2)
    count.set(3)
    expect(double.get()).toBe(6)
    count.update((n) => n + 1)
    expect(count.peek()).toBe(4)
  })

  it("runs an effect on change and stops after dispose", () => {
    const count = signal(0)
    const seen: number[] = []
    const dispose = effect(() => {
      seen.push(count.get())
    })
    count.set(1)
    dispose()
    count.set(2)
    expect(seen).toEqual([0, 1])
  })

  it("does not notify on an equal value", () => {
    const value = signal({ id: 1 }, { equals: (a, b) => a.id === b.id })
    let runs = 0
    effect(() => {
      value.get()
      runs += 1
    })
    value.set({ id: 1 })
    expect(runs).toBe(1)
  })

  it("batches writes into one notification", () => {
    const a = signal(1)
    const b = signal(1)
    const sums: number[] = []
    effect(() => {
      sums.push(a.get() + b.get())
    })
    batch(() => {
      a.set(2)
      b.set(2)
    })
    expect(sums).toEqual([2, 4])
  })

  it("does not track reads inside untracked", () => {
    const a = signal(1)
    let runs = 0
    effect(() => {
      untracked(() => a.get())
      runs += 1
    })
    a.set(2)
    expect(runs).toBe(1)
  })

  it("disposes the effects of a scope together", () => {
    const a = signal(0)
    let runs = 0
    const dispose = scope(() => {
      effect(() => {
        a.get()
        runs += 1
      })
    })
    dispose()
    a.set(1)
    expect(runs).toBe(1)
  })
})
