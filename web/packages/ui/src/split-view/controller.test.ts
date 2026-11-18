// @vitest-environment happy-dom
import { afterEach, describe, expect, test } from "vitest"
import { h, keydown, mount, pointer } from "../testing/dom"
import { type SplitViewState, SplitViewController } from "./controller"

const panes = [
  { id: "sidebar", size: 240, minSize: 180, maxSize: 340, collapsible: true, label: "Sidebar" },
  { id: "main", flex: true, minSize: 300 },
  { id: "inspector", size: 280, minSize: 220, maxSize: 400 },
]

const setup = (initial?: Partial<SplitViewState>, dir?: "rtl") => {
  const changes: SplitViewState[] = []
  const split = new SplitViewController({ panes, initial, onChange: (state) => changes.push(state) })
  const root = mount(h("div", dir ? { dir } : {}))
  split.root.attach(root)
  split.setContainerSize(1000)
  const left = h("div")
  const right = h("div")
  root.append(left, right)
  split.separator(0).attach(left)
  split.separator(1).attach(right)
  return { split, left, right, changes }
}

afterEach(() => document.body.replaceChildren())

describe("split view", () => {
  test("sizes, the flexible remainder, and separator ARIA", () => {
    const { split, left, right } = setup()
    expect(split.size("sidebar").peek()).toBe(240)
    expect(split.size("main").peek()).toBe(1000 - 240 - 280)
    expect(left.getAttribute("role")).toBe("separator")
    expect(left.getAttribute("aria-orientation")).toBe("vertical")
    expect(left.getAttribute("aria-valuenow")).toBe("240")
    expect(left.getAttribute("aria-valuemin")).toBe("0")
    expect(left.getAttribute("aria-valuemax")).toBe("340")
    expect(left.getAttribute("aria-controls")).toBe(`${split.id}-sidebar`)
    expect(left.getAttribute("aria-label")).toBe("Sidebar")
    expect(right.getAttribute("aria-valuenow")).toBe("280")
  })

  test("arrows resize by the step (Shift for more), clamped; the second separator resizes the pane after it", () => {
    const { split, left, right, changes } = setup()
    keydown(left, "ArrowRight")
    expect(split.size("sidebar").peek()).toBe(250)
    keydown(left, "ArrowRight", { shiftKey: true })
    keydown(left, "ArrowRight", { shiftKey: true })
    expect(split.size("sidebar").peek()).toBe(340)
    keydown(right, "ArrowLeft")
    expect(split.size("inspector").peek()).toBe(290)
    keydown(right, "End")
    // The main pane keeps its 300px minimum.
    expect(split.size("inspector").peek()).toBe(1000 - 340 - 300)
    expect(changes.at(-1)).toEqual({ sizes: { sidebar: 340, inspector: 360 }, collapsed: [] })
  })

  test("a collapsible pane collapses below its minimum and Enter toggles it back", () => {
    const { split, left } = setup({ sizes: { sidebar: 190 } })
    keydown(left, "ArrowLeft", { shiftKey: true })
    expect(split.isCollapsed("sidebar").peek()).toBe(true)
    expect(split.size("sidebar").peek()).toBe(0)
    expect(left.getAttribute("aria-valuenow")).toBe("0")
    keydown(left, "Enter")
    expect(split.size("sidebar").peek()).toBe(190)
    keydown(left, "Home")
    expect(split.isCollapsed("sidebar").peek()).toBe(true)
    keydown(left, "ArrowRight")
    expect(split.isCollapsed("sidebar").peek()).toBe(false)
  })

  test("dragging resizes, collapses past half the minimum, and reports once on release", () => {
    const { split, left, changes } = setup()
    pointer(left, "pointerdown", { clientX: 240, pointerId: 1 })
    pointer(left, "pointermove", { clientX: 300, pointerId: 1 })
    expect(split.size("sidebar").peek()).toBe(300)
    pointer(left, "pointermove", { clientX: 100, pointerId: 1 })
    expect(split.size("sidebar").peek()).toBe(180)
    pointer(left, "pointermove", { clientX: 60, pointerId: 1 })
    expect(split.isCollapsed("sidebar").peek()).toBe(true)
    pointer(left, "pointermove", { clientX: 200, pointerId: 1 })
    expect(split.size("sidebar").peek()).toBe(200)
    expect(changes).toHaveLength(0)
    pointer(left, "pointerup", { clientX: 200, pointerId: 1 })
    expect(changes).toEqual([{ sizes: { sidebar: 200, inspector: 280 }, collapsed: [] }])
  })

  test("right to left mirrors keys and drags", () => {
    const { split, left } = setup(undefined, "rtl")
    keydown(left, "ArrowLeft")
    expect(split.size("sidebar").peek()).toBe(250)
    pointer(left, "pointerdown", { clientX: 700, pointerId: 2 })
    pointer(left, "pointermove", { clientX: 680, pointerId: 2 })
    expect(split.size("sidebar").peek()).toBe(270)
  })

  test("restores persisted state, ignoring nonsense", () => {
    const { split } = setup({ sizes: { sidebar: 9999, inspector: Number.NaN }, collapsed: ["sidebar", "inspector"] })
    expect(split.isCollapsed("sidebar").peek()).toBe(true)
    expect(split.isCollapsed("inspector").peek()).toBe(false)
    expect(split.state()).toEqual({ sizes: { sidebar: 340, inspector: 280 }, collapsed: ["sidebar"] })
  })
})
