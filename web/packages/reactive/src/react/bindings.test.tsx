// @vitest-environment happy-dom
import { StrictMode, useState } from "react"
import { afterEach, describe, expect, it } from "vitest"
import { computed, effect, signal } from "../signals"
import { useElement, useModel, useSignal } from "./index"
import { mount, update, type Mounted } from "./testing"

let mounted: Mounted | undefined

afterEach(() => {
  mounted?.unmount()
  mounted = undefined
})

const flushMicrotasks = () => new Promise<void>((resolve) => setTimeout(resolve, 0))

describe("useSignal", () => {
  it("renders the current value and re-renders on change", () => {
    const count = signal(1)
    const double = computed(() => count.get() * 2)
    function View() {
      return (
        <span>
          {useSignal(count)}:{useSignal(double)}
        </span>
      )
    }
    mounted = mount(<View />)
    expect(mounted.container.textContent).toBe("1:2")
    update(() => count.set(5))
    expect(mounted.container.textContent).toBe("5:10")
  })

  it("stops observing after unmount", () => {
    const value = signal(0)
    let observers = 0
    const watched = computed(() => {
      observers += 1
      return value.get()
    })
    function View() {
      return <span>{useSignal(watched)}</span>
    }
    const view = mount(<View />)
    view.unmount()
    const before = observers
    value.set(1)
    expect(observers).toBe(before)
  })

  it("re-renders once for a batch of writes", () => {
    const a = signal(0)
    const b = signal(0)
    let renders = 0
    function View() {
      renders += 1
      return (
        <span>
          {useSignal(a)}
          {useSignal(b)}
        </span>
      )
    }
    mounted = mount(<View />)
    renders = 0
    update(() => {
      a.set(1)
      b.set(1)
    })
    expect(renders).toBe(1)
    expect(mounted.container.textContent).toBe("11")
  })

  it("picks up a change made between render and subscribe", () => {
    const value = signal("a")
    function View() {
      const current = useSignal(value)
      if (current === "a") value.set("b")
      return <span>{current}</span>
    }
    mounted = mount(<View />)
    expect(mounted.container.textContent).toBe("b")
  })
})

describe("useModel", () => {
  const makeModel = (log: string[], name = "model") => {
    const source = signal(0)
    log.push(`create ${name}`)
    effect(() => {
      source.get()
      return () => log.push(`effect cleanup ${name}`)
    })
    return {
      name,
      source,
      dispose: () => log.push(`dispose ${name}`),
    }
  }

  it("creates the model in the first render and disposes it with its effects on unmount", async () => {
    const log: string[] = []
    let seen: string | undefined
    function View() {
      const model = useModel(() => makeModel(log))
      seen = model.name
      return null
    }
    const view = mount(<View />)
    expect(seen).toBe("model")
    expect(log).toEqual(["create model"])
    view.unmount()
    await flushMicrotasks()
    expect(log).toEqual(["create model", "effect cleanup model", "dispose model"])
  })

  it("keeps one model under StrictMode's double render and effect replay, and disposes it once", async () => {
    const log: string[] = []
    const models = new Set<unknown>()
    function View() {
      const model = useModel(() => makeModel(log))
      models.add(model)
      return null
    }
    const view = mount(
      <StrictMode>
        <View />
      </StrictMode>,
    )
    await flushMicrotasks()
    expect(models.size).toBe(1)
    expect(log).toEqual(["create model"])
    view.unmount()
    await flushMicrotasks()
    expect(log).toEqual(["create model", "effect cleanup model", "dispose model"])
  })

  it("recreates the model when its deps change and disposes the old one", async () => {
    const log: string[] = []
    let setId!: (id: number) => void
    function View() {
      const [id, set] = useState(1)
      setId = set
      useModel(() => makeModel(log, `chat ${id}`), [id])
      return null
    }
    mounted = mount(<View />)
    update(() => setId(2))
    await flushMicrotasks()
    expect(log).toEqual(["create chat 1", "create chat 2", "effect cleanup chat 1", "dispose chat 1"])
  })
})

describe("useElement", () => {
  it("attaches the element and runs the cleanup when it goes away", () => {
    const log: string[] = []
    const controller = {
      attach: (element: HTMLElement) => {
        log.push(`attach ${element.tagName}`)
        return () => log.push("detach")
      },
    }
    let setShown!: (shown: boolean) => void
    function View() {
      const [shown, set] = useState(true)
      setShown = set
      const ref = useElement(controller)
      return shown ? <div ref={ref} /> : null
    }
    mounted = mount(<View />)
    expect(log).toEqual(["attach DIV"])
    update(() => setShown(false))
    expect(log).toEqual(["attach DIV", "detach"])
  })

  it("does not re-attach on a re-render with the same controller", () => {
    const log: string[] = []
    const controller = (element: HTMLElement) => {
      log.push(`attach ${element.tagName}`)
      return () => log.push("detach")
    }
    let rerender!: () => void
    function View() {
      const [, set] = useState(0)
      rerender = () => set((n) => n + 1)
      return <span ref={useElement(controller)} />
    }
    mounted = mount(<View />)
    update(() => rerender())
    expect(log).toEqual(["attach SPAN"])
  })
})
