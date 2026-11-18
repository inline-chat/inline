import { describe, expect, it } from "vitest"
import { assessEnvironment, browserName, demoSearch, describeRun, frameVerdict, parseLabParams, type EnvironmentFacts } from "./environment"

const facts: EnvironmentFacts = {
  dev: false,
  demoEnabled: true,
  visibility: "visible",
  frameVisible: true,
  fps: 60,
  cpuDeclared: 4,
  scale: "large",
  role: "leader",
  panes: 1,
  supports: { longtask: true, longAnimationFrame: true, eventTiming: true, memory: true, compressionStream: true },
}

describe("parameters", () => {
  it("defaults to the medium scale and reads the rest", () => {
    expect(parseLabParams("")).toEqual({ scale: "medium", seed: undefined, storage: undefined, cpu: undefined, autorun: false })
    expect(parseLabParams("?scale=large&seed=7&storage=memory&cpu=4&run=all")).toEqual({
      scale: "large",
      seed: 7,
      storage: "memory",
      cpu: 4,
      autorun: true,
    })
  })

  it("ignores values it does not understand", () => {
    expect(parseLabParams("?scale=huge&seed=-1&storage=disk&cpu=abc")).toMatchObject({
      scale: "medium",
      seed: undefined,
      storage: undefined,
      cpu: undefined,
    })
  })

  it("builds the app's demo query", () => {
    expect(demoSearch({ scale: "small", seed: undefined, storage: undefined })).toBe("?demo=small")
    expect(demoSearch({ scale: "large", seed: 3, storage: "opfs" })).toBe("?demo=large&seed=3&storage=opfs")
  })
})

describe("frame grading", () => {
  it("allows frame-time grading at 30 fps or more in a visible page", () => {
    expect(frameVerdict(facts)).toEqual({ allowed: true })
    expect(frameVerdict({ ...facts, fps: 30 }).allowed).toBe(true)
  })

  it("refuses below 30 fps, in a hidden page, an off-screen frame or with no reading", () => {
    expect(frameVerdict({ ...facts, fps: 4.2 })).toEqual({
      allowed: false,
      reason: "not measured: frames throttled (4 fps, under 30)",
    })
    expect(frameVerdict({ ...facts, visibility: "hidden" }).reason).toBe("not measured: page hidden")
    expect(frameVerdict({ ...facts, frameVisible: false }).reason).toBe("not measured: app frame off screen")
    expect(frameVerdict({ ...facts, fps: undefined }).allowed).toBe(false)
  })
})

describe("assessment", () => {
  it("has nothing to say about the reference setup", () => {
    expect(assessEnvironment(facts)).toEqual({ frames: { allowed: true }, warnings: [], meaningful: true })
  })

  it("flags a development build, unknown throttling, a small scale, a follower and missing APIs", () => {
    const result = assessEnvironment({
      ...facts,
      dev: true,
      cpuDeclared: undefined,
      scale: "medium",
      role: "follower",
      panes: 2,
      supports: { ...facts.supports, longAnimationFrame: false, memory: false },
    })
    expect(result.meaningful).toBe(false)
    const text = result.warnings.join("\n")
    expect(text).toContain("Development build")
    expect(text).toContain("CPU throttling unknown")
    expect(text).toContain("?cpu=4")
    expect(text).toContain("Scale medium")
    expect(text).toContain("follower")
    expect(text).toContain("2 panes")
    expect(text).toContain("Long Animation Frames")
    expect(text).toContain("performance.memory")
  })

  it("notes throttling other than 4x and throttled frames", () => {
    const result = assessEnvironment({ ...facts, cpuDeclared: 6, fps: 10 })
    expect(result.frames.allowed).toBe(false)
    expect(result.warnings.some((w) => w.includes("declared as 6x"))).toBe(true)
    expect(result.warnings.some((w) => w.includes("frames throttled"))).toBe(true)
    expect(result.meaningful).toBe(true)
  })

  it("is not meaningful in a hidden page or without the demo", () => {
    expect(assessEnvironment({ ...facts, visibility: "hidden" }).meaningful).toBe(false)
    expect(assessEnvironment({ ...facts, demoEnabled: false }).meaningful).toBe(false)
  })
})

describe("run description", () => {
  it("names the browser from the user agent", () => {
    expect(browserName("Mozilla/5.0 (Macintosh) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/156.0.0.0 Safari/537.36")).toBe(
      "Chromium 156",
    )
    expect(browserName("Mozilla/5.0 (Macintosh; rv:140.0) Gecko/20100101 Firefox/140.0")).toBe("Firefox 140")
    expect(browserName("Mozilla/5.0 (Macintosh) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.1 Safari/605.1.15")).toBe(
      "Safari 26",
    )
    expect(browserName("curl/8")).toBe("unknown browser")
  })

  it("puts every condition on one line", () => {
    expect(
      describeRun({
        date: "2026-11-17 10:00",
        facts,
        browser: "Chromium 156",
        devicePixelRatio: 2,
        frameSize: "900×800",
        cpuProbeMs: 41.6,
        seed: 1,
        storage: "opfs",
      }),
    ).toBe("2026-11-17 10:00, scale large seed 1 opfs, production build, CPU 4x declared, 60 fps, Chromium 156, DPR 2, app frame 900×800, CPU probe 42 ms")
  })
})
