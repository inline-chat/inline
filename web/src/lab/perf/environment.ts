/**
 * The lab's parameters and the conditions that make a run meaningful or
 * not. Pure and DOM-free; `main.ts` gathers the facts in the browser and
 * passes them in. Tested in `environment.test.ts`.
 */

export type Scale = "small" | "medium" | "large"

export type LabParams = {
  scale: Scale
  seed: number | undefined
  storage: "opfs" | "memory" | undefined
  /** CPU slowdown the user says DevTools applies (`?cpu=4`); the page cannot detect it. */
  cpu: number | undefined
  /** `?run=all`: start every journey once the page is up. */
  autorun: boolean
}

/** `lab-perf.html?scale=small|medium|large[&seed=N][&storage=opfs|memory][&cpu=4][&run=all]`. */
export const parseLabParams = (search: string): LabParams => {
  const params = new URLSearchParams(search)
  const scale = params.get("scale")
  const seed = Number(params.get("seed"))
  const storage = params.get("storage")
  const cpu = Number(params.get("cpu"))
  return {
    scale: scale === "small" || scale === "large" ? scale : "medium",
    seed: params.has("seed") && Number.isSafeInteger(seed) && seed >= 0 ? seed : undefined,
    storage: storage === "opfs" || storage === "memory" ? storage : undefined,
    cpu: params.has("cpu") && Number.isFinite(cpu) && cpu >= 1 && cpu <= 20 ? cpu : undefined,
    autorun: params.get("run") === "all",
  }
}

/** The app's demo query for these parameters (`web/src/app/demo-params.ts`). */
export const demoSearch = (params: Pick<LabParams, "scale" | "seed" | "storage">): string => {
  const query = new URLSearchParams({ demo: params.scale })
  if (params.seed !== undefined) query.set("seed", String(params.seed))
  if (params.storage !== undefined) query.set("storage", params.storage)
  return `?${query.toString()}`
}

/** Below this frame rate the window is throttled, and frame-time rows are not graded. */
export const MIN_FPS = 30

export type EnvironmentFacts = {
  /** A development build (Vite dev server): timings are not representative. */
  dev: boolean
  /** The build boots the demo (the labs build's `__INLINE_DEMO__`). */
  demoEnabled: boolean
  visibility: "visible" | "hidden"
  /** The app's frame is on screen (intersection with the viewport), when known. */
  frameVisible: boolean | undefined
  /** Measured animation frame rate in the app's frame, when measured. */
  fps: number | undefined
  cpuDeclared: number | undefined
  scale: Scale
  /** The app's link role: a follower tab does not run the core. */
  role: string | null | undefined
  panes: number | undefined
  supports: {
    longtask: boolean
    longAnimationFrame: boolean
    eventTiming: boolean
    memory: boolean
    compressionStream: boolean
  }
}

export type FrameGradingVerdict = { allowed: boolean; reason?: string }

export type EnvironmentAssessment = {
  frames: FrameGradingVerdict
  /** Conditions the reader of the table must know about. */
  warnings: string[]
  /** False when nothing timed in this run means anything (development build, hidden page). */
  meaningful: boolean
}

/** Whether frame-time rows can be graded, from the visibility and the measured frame rate. */
export const frameVerdict = (facts: Pick<EnvironmentFacts, "visibility" | "frameVisible" | "fps">): FrameGradingVerdict => {
  if (facts.visibility === "hidden") return { allowed: false, reason: "not measured: page hidden" }
  if (facts.frameVisible === false) return { allowed: false, reason: "not measured: app frame off screen" }
  if (facts.fps === undefined) return { allowed: false, reason: "not measured: frame rate unknown" }
  if (facts.fps < MIN_FPS) {
    return { allowed: false, reason: `not measured: frames throttled (${Math.round(facts.fps)} fps, under ${MIN_FPS})` }
  }
  return { allowed: true }
}

export const CPU_THROTTLING_HOWTO =
  "DevTools > Performance > settings (gear) > CPU: 4x slowdown, keep DevTools open, and open the lab with ?cpu=4"

export const assessEnvironment = (facts: EnvironmentFacts): EnvironmentAssessment => {
  const warnings: string[] = []
  const frames = frameVerdict(facts)
  if (facts.dev) warnings.push("Development build: timings are not representative. Build the labs and use vite preview.")
  if (!facts.demoEnabled) warnings.push("This build does not boot the demo (build it with tooling/vite.labs.config.ts); the journeys cannot run.")
  if (!frames.allowed) warnings.push(`Frame-time rows are ${frames.reason ?? "not measured"}. Keep the lab window in front.`)
  if (facts.cpuDeclared === undefined) {
    warnings.push(`CPU throttling unknown; the budgets are for 4x. Set it: ${CPU_THROTTLING_HOWTO}.`)
  } else if (facts.cpuDeclared !== 4) {
    warnings.push(`CPU throttling declared as ${facts.cpuDeclared}x; the budgets are for 4x.`)
  }
  if (facts.scale !== "large") warnings.push(`Scale ${facts.scale}: the sidebar budget is for the large scale (?scale=large).`)
  if (facts.role === "follower") {
    warnings.push("The app is a follower tab: another tab of this demo runs the core. Close other tabs of the demo.")
  }
  if (facts.panes !== undefined && facts.panes > 1) warnings.push(`${facts.panes} panes open; the journeys drive the first.`)
  if (!facts.supports.longAnimationFrame) warnings.push("Long Animation Frames are not supported here (Chromium only).")
  if (!facts.supports.longtask) warnings.push("Long tasks are not reported by this browser.")
  if (!facts.supports.memory) warnings.push("performance.memory is not available (non-standard, Chromium only): no heap row.")
  return { frames, warnings, meaningful: !facts.dev && facts.visibility === "visible" && facts.demoEnabled }
}

/** One line describing the run, for the top of the Markdown table. */
export const describeRun = (input: {
  date: string
  facts: EnvironmentFacts
  browser: string
  devicePixelRatio: number
  frameSize: string
  cpuProbeMs: number | undefined
  seed: number | undefined
  storage: string | undefined
}): string => {
  const f = input.facts
  const parts = [
    input.date,
    `scale ${f.scale}${input.seed !== undefined ? ` seed ${input.seed}` : ""}${input.storage ? ` ${input.storage}` : ""}`,
    f.dev ? "development build" : "production build",
    f.cpuDeclared === undefined ? "CPU throttling not declared" : `CPU ${f.cpuDeclared}x declared`,
    f.fps === undefined ? "frame rate unknown" : `${Math.round(f.fps)} fps`,
    input.browser,
    `DPR ${input.devicePixelRatio}`,
    `app frame ${input.frameSize}`,
  ]
  if (input.cpuProbeMs !== undefined) parts.push(`CPU probe ${Math.round(input.cpuProbeMs)} ms`)
  return parts.join(", ")
}

/** A short browser name from a user agent string: "Chromium 156", "Firefox 140", "Safari 26". */
export const browserName = (userAgent: string): string => {
  const edge = /Edg\/(\d+)/.exec(userAgent)
  if (edge) return `Edge ${edge[1]}`
  const chrome = /(?:Chrome|Chromium)\/(\d+)/.exec(userAgent)
  if (chrome) return `Chromium ${chrome[1]}`
  const firefox = /Firefox\/(\d+)/.exec(userAgent)
  if (firefox) return `Firefox ${firefox[1]}`
  const safari = /Version\/(\d+)[^ ]* .*Safari\//.exec(userAgent)
  if (safari) return `Safari ${safari[1]}`
  return "unknown browser"
}
