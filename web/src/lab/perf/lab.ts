/**
 * The perf lab's state and its control: one journey at a time, rows merged
 * into one table, the environment checked at the start of every run, and the
 * same data on `globalThis.__perfLab` as on the page.
 */

import { errorRows, gradeCounts, mergeRows, type ResultRow } from "./budgets"
import {
  assessEnvironment,
  browserName,
  demoSearch,
  describeRun,
  type EnvironmentAssessment,
  type EnvironmentFacts,
  type LabParams,
  type Scale,
} from "./environment"
import { AppFrame } from "./host"
import { DEFAULT_SAMPLES, JOURNEY_BUDGETS, JOURNEYS, Journeys, type JourneyName, type MemoryReading, type SampleCounts } from "./journeys"
import { toMarkdown } from "./markdown"
import { cpuProbe, measureFrameTimes, waitFrames } from "./probes"
import { framesPerSecond, roundTo } from "./stats"
import { browserFrameScheduler, createFrameWaiter } from "../timeline/frames"

export type LabStatus = "idle" | "loading" | "running" | "done" | "error"

export type EnvironmentReport = {
  date: string
  url: string
  browser: string
  userAgent: string
  devicePixelRatio: number
  frameSize: string
  cpuProbeMs: number | undefined
  facts: EnvironmentFacts
  assessment: EnvironmentAssessment
  line: string
}

export type PerfLabSnapshot = {
  status: LabStatus
  /** The journey running now. */
  running: JourneyName | null
  message: string
  params: LabParams
  environment: EnvironmentReport | null
  warnings: string[]
  rows: ResultRow[]
  counts: ReturnType<typeof gradeCounts>
  /** Raw samples per journey. */
  raw: Partial<Record<JourneyName | "firstLoad", unknown>>
  markdown: string
  startedAt: string | null
  finishedAt: string | null
}

export type RunAllOptions = {
  /** Journeys to run, in the lab's order (default: all). */
  journeys?: readonly JourneyName[]
  /** Load the app at this scale first (the page's `?scale=` otherwise). */
  scale?: Scale
  /** Override sample counts. */
  samples?: Partial<SampleCounts>
}

export type PerfLabControl = { [K in JourneyName]: (options?: { samples?: Partial<SampleCounts> }) => Promise<ResultRow[]> } & {
  runAll(options?: RunAllOptions): Promise<PerfLabSnapshot>
  /** Collect and assess the environment now. */
  environment(): Promise<EnvironmentReport>
  /** Load the app frame (again) at the page's scale. */
  load(scale?: Scale): Promise<void>
  markdown(): string
  snapshot(): PerfLabSnapshot
}

export const TITLE = "Inline web perf lab"

export const createPerfLab = (options: {
  iframe: HTMLIFrameElement
  params: LabParams
  frameVisible: () => boolean | undefined
  onChange: (snapshot: PerfLabSnapshot) => void
}) => {
  const waiter = createFrameWaiter(browserFrameScheduler())
  const frame = new AppFrame(options.iframe, waiter)
  let params = options.params
  let samples: SampleCounts = DEFAULT_SAMPLES
  let memoryBefore: MemoryReading | undefined
  const domSamples: number[] = []

  const state: Omit<PerfLabSnapshot, "markdown" | "counts"> = {
    status: "idle",
    running: null,
    message: "Not started. Run all, or one journey.",
    params,
    environment: null,
    warnings: [],
    rows: [],
    raw: {},
    startedAt: null,
    finishedAt: null,
  }

  const markdown = () =>
    toMarkdown({
      title: TITLE,
      run: state.environment?.line ?? "environment not collected",
      warnings: state.warnings,
      rows: state.rows,
    })

  const snapshot = (): PerfLabSnapshot => ({
    ...state,
    rows: [...state.rows],
    counts: gradeCounts(state.rows),
    markdown: markdown(),
  })

  const changed = () => options.onChange(snapshot())

  const journeys = new Journeys({
    frame,
    get scale() {
      return params.scale
    },
    samples: () => samples,
    frameVisible: options.frameVisible,
    memoryBefore: () => memoryBefore,
    domSamples: () => domSamples,
  })

  const ensureLoaded = async (scale: Scale = params.scale) => {
    const search = demoSearch({ ...params, scale })
    if (frame.loads > 0 && frame.search === search && frame.peekApp()?.phase === "signedIn") return
    params = { ...params, scale }
    state.params = params
    state.status = "loading"
    state.message = `Loading the app at the ${scale} scale…`
    changed()
    const started = performance.now()
    await frame.load(search)
    const win = frame.win()
    const read = (name: string) => {
      const entry = win.performance.getEntriesByName(name, "measure")[0]
      return entry ? roundTo(entry.startTime + entry.duration, 1) : undefined
    }
    state.raw.firstLoad = {
      scale,
      totalMs: roundTo(performance.now() - started, 1),
      shellPaint: read("inline.boot.shell-paint"),
      coreReady: read("inline.boot.core-ready"),
      sidebarRows: read("inline.boot.sidebar-rows"),
      note: "the lab's first load of the app; not graded (the demo may be seeding, the service worker installing)",
    }
  }

  const collectEnvironment = async (): Promise<EnvironmentReport> => {
    const win = frame.win()
    const fps = framesPerSecond(await measureFrameTimes(win, 30))
    const app = frame.peekApp()
    const facts: EnvironmentFacts = {
      dev: import.meta.env.DEV,
      demoEnabled: import.meta.env.DEV || __INLINE_DEMO__,
      visibility: document.visibilityState,
      frameVisible: options.frameVisible(),
      fps,
      cpuDeclared: params.cpu,
      scale: params.scale,
      role: app?.role,
      panes: app?.panes.length,
      supports: journeys.supports(win),
    }
    const assessment = assessEnvironment(facts)
    const rect = options.iframe.getBoundingClientRect()
    const report: EnvironmentReport = {
      date: new Date().toISOString(),
      url: location.href,
      browser: browserName(navigator.userAgent),
      userAgent: navigator.userAgent,
      devicePixelRatio: globalThis.devicePixelRatio,
      frameSize: `${Math.round(rect.width)}×${Math.round(rect.height)}`,
      cpuProbeMs: cpuProbe(() => performance.now()),
      facts,
      assessment,
      line: "",
    }
    report.line = describeRun({
      date: report.date.slice(0, 16).replace("T", " "),
      facts,
      browser: report.browser,
      devicePixelRatio: report.devicePixelRatio,
      frameSize: report.frameSize,
      cpuProbeMs: report.cpuProbeMs,
      seed: params.seed,
      storage: params.storage,
    })
    state.environment = report
    state.warnings = assessment.warnings
    changed()
    return report
  }

  let queue: Promise<unknown> = Promise.resolve()
  /** One thing at a time: journeys share the app and the main thread. */
  const serial = <T>(fn: () => Promise<T>): Promise<T> => {
    const next = queue.then(fn, fn)
    queue = next.catch(() => undefined)
    return next
  }

  const runJourney = async (name: JourneyName): Promise<ResultRow[]> => {
    state.status = "running"
    state.running = name
    state.message = `Running ${name}…`
    changed()
    let rows: ResultRow[]
    try {
      await ensureLoaded()
      if (state.environment === null) await collectEnvironment()
      const result = await journeys[name]()
      rows = result.rows
      state.raw[name] = result.raw
    } catch (error) {
      rows = errorRows(name, JOURNEY_BUDGETS[name], error)
      state.raw[name] = { error: error instanceof Error ? `${error.name}: ${error.message}` : String(error) }
    }
    try {
      if (frame.loads > 0) domSamples.push(journeys.readMemory().elements)
    } catch {
      // The frame is between documents; the next journey samples it.
    }
    state.rows = mergeRows(state.rows, rows)
    state.running = null
    changed()
    return rows
  }

  const single =
    (name: JourneyName) =>
    (runOptions: { samples?: Partial<SampleCounts> } = {}) =>
      serial(async () => {
        samples = { ...DEFAULT_SAMPLES, ...runOptions.samples }
        state.startedAt = new Date().toISOString()
        const rows = await runJourney(name)
        state.status = rows.some((row) => row.grade === "error") ? "error" : "done"
        state.message = `${name}: ${rows.map((row) => `${row.id} ${row.grade}`).join(", ")}`
        state.finishedAt = new Date().toISOString()
        changed()
        return rows
      })

  const runAll = (runOptions: RunAllOptions = {}) =>
    serial(async () => {
      samples = { ...DEFAULT_SAMPLES, ...runOptions.samples }
      state.startedAt = new Date().toISOString()
      state.finishedAt = null
      try {
        await ensureLoaded(runOptions.scale ?? params.scale)
        await waitFrames(frame.win(), 30)
        await collectEnvironment()
        memoryBefore = journeys.readMemory()
        domSamples.length = 0
        const wanted = new Set(runOptions.journeys ?? JOURNEYS)
        for (const name of JOURNEYS) if (wanted.has(name)) await runJourney(name)
        const counts = gradeCounts(state.rows)
        state.status = counts.error > 0 ? "error" : "done"
        state.message = `Done: ${counts.pass} pass, ${counts.fail} fail, ${counts.inconclusive} inconclusive, ${counts["not-measured"]} not measured, ${counts.error} errors.`
      } catch (error) {
        state.status = "error"
        state.message = error instanceof Error ? error.message : String(error)
      }
      state.running = null
      state.finishedAt = new Date().toISOString()
      changed()
      return snapshot()
    })

  const control = Object.fromEntries(JOURNEYS.map((name) => [name, single(name)])) as Record<
    JourneyName,
    (options?: { samples?: Partial<SampleCounts> }) => Promise<ResultRow[]>
  >

  const labControl: PerfLabControl = {
    ...control,
    runAll,
    environment: () =>
      serial(async () => {
        await ensureLoaded()
        return collectEnvironment()
      }),
    load: (scale) =>
      serial(async () => {
        await ensureLoaded(scale)
        state.status = "idle"
        state.message = "App loaded."
        changed()
      }),
    markdown,
    snapshot,
  }

  return { control: labControl, snapshot, frame }
}
