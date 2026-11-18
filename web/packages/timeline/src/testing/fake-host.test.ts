import { describe, expect, it } from "vitest"
import type { HostEvent } from "../host"
import { createFakeHost } from "./fake-host"

const rows = (count: number, height = 100) => Array.from({ length: count }, (_, i) => ({ key: `r${i}`, height }))

describe("fake host", () => {
  it("lays rows out top-down and reports geometry in viewport coordinates", () => {
    const fake = createFakeHost({ viewportHeight: 250, paddingTop: 10 })
    fake.setRows(rows(5))
    expect(fake.contentHeight()).toBe(510)
    fake.host.setScrollOffset(120)
    expect(fake.host.rowRect("r1")).toEqual({ top: -10, bottom: 90 })
    expect(fake.host.visibleKeys()).toEqual(["r1", "r2", "r3"])
    expect(fake.host.rowKeys()).toEqual(["r0", "r1", "r2", "r3", "r4"])
  })

  it("clamps and rounds offsets to device pixels", () => {
    const fake = createFakeHost({ viewportHeight: 250, devicePixelRatio: 2 })
    fake.setRows(rows(5))
    fake.host.setScrollOffset(100.3)
    expect(fake.offset()).toBe(100.5)
    fake.host.setScrollOffset(9999)
    expect(fake.offset()).toBe(250)
  })

  it("orders a frame like a browser: scroll event, frame callbacks, observer entries", () => {
    const fake = createFakeHost({ viewportHeight: 250 })
    const log: string[] = []
    fake.host.subscribe((event: HostEvent) => log.push(event.kind))
    fake.setRows(rows(5))
    expect(log).toEqual(["rows"])
    fake.host.setScrollOffset(50)
    fake.resizeRow("r0", 120)
    fake.frames.request(() => log.push("frame"))
    expect(log).toEqual(["rows"])
    fake.frame()
    expect(log).toEqual(["rows", "scroll", "frame", "resize"])
  })

  it("dispatches a clamp's scroll event in the frame after the observer entries", () => {
    const fake = createFakeHost({ viewportHeight: 250 })
    const log: string[] = []
    fake.setRows(rows(5))
    fake.host.setScrollOffset(250)
    fake.frame()
    fake.host.subscribe((event: HostEvent) => log.push(event.kind))
    fake.resizeRow("r4", 10)
    expect(fake.offset()).toBe(160)
    fake.frame()
    expect(log).toEqual(["resize"])
    fake.frame()
    expect(log).toEqual(["resize", "scroll"])
  })

  it("runs timers in order on virtual time", () => {
    const fake = createFakeHost()
    const fired: string[] = []
    fake.clock.setTimeout(() => fired.push("b"), 40)
    fake.clock.setTimeout(() => fired.push("a"), 20)
    const cancel = fake.clock.setTimeout(() => fired.push("x"), 30)
    cancel()
    fake.advance(48)
    expect(fired).toEqual(["a", "b"])
    expect(fake.now()).toBe(48)
  })

  it("emits user input before moving, and the scroll on the next frame", () => {
    const fake = createFakeHost({ viewportHeight: 250 })
    fake.setRows(rows(5))
    const log: string[] = []
    fake.host.subscribe((event: HostEvent) => log.push(event.kind === "input" ? `input:${event.direction}` : event.kind))
    fake.userScroll(-30)
    expect(log).toEqual(["input:up"])
    expect(fake.offset()).toBe(0)
    fake.userScroll(40)
    fake.frame()
    expect(log).toEqual(["input:up", "input:down", "scroll"])
  })

  it.each([
    ["round", 100, 1, 100],
    ["floor", 100.7, 1, 100],
    ["ceil", 100.2, 1, 101],
    ["none", 100.3, 1, 100.3],
    ["floor", 100.7, 2, 100.5],
  ] as const)("snaps a written offset with %s (%s at %sx reads %s)", (scrollRounding, written, devicePixelRatio, read) => {
    const fake = createFakeHost({ viewportHeight: 250, scrollRounding, devicePixelRatio })
    fake.setRows(rows(5))
    fake.host.setScrollOffset(written)
    expect(fake.offset()).toBe(read)
  })

  it("snaps a deferred write only when the frame commits it", () => {
    const fake = createFakeHost({ viewportHeight: 250, scrollRounding: "deferred", devicePixelRatio: 1 })
    fake.setRows(rows(5))
    fake.host.setScrollOffset(100.6)
    expect(fake.offset()).toBe(100.6)
    fake.frame()
    expect(fake.offset()).toBe(101)
  })
})
