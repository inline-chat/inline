/**
 * The journeys: each puts the app in a known state, drives it through its
 * own surfaces, measures one or more budget moments and returns result rows
 * plus its raw samples. Journeys leave the demo usable for the next run (the
 * composer empty, the list following latest, the sidebar at the top).
 *
 * Input, per journey (the `input` column):
 * - chat switches: `click()` on the sidebar row (an untrusted click through
 *   the sidebar's own click handler);
 * - send and typing: text inserted with `document.execCommand("insertText")`
 *   into the focused composer (the browser's editing pipeline, then the
 *   composer's `input` read-back, as for plain typing) and `keydown` events
 *   dispatched on the editor (Enter sends through the composer's key map);
 * - incoming, streaming and the sidebar update: the demo control channel
 *   (`__inlineDemo`);
 * - scrolling: a synthetic `wheel` on the scroller followed by the scroll the
 *   browser would perform, as in the timeline lab;
 * - warm start: a reload of the app's frame.
 *
 * Event Timing (`PerformanceObserver` type `event`) reports trusted input
 * only, so it cannot time script-driven input: input times are
 * `performance.now()` just before the input is dispatched, and paint times
 * are "a frame, then a task" after the result is in the DOM (the app's own
 * definition in `web/src/app/perf.ts`).
 */

import type { BudgetId, Extra, ResultRow } from "./budgets"
import { budgetById, budgetRow, infoRow } from "./budgets"
import { frameVerdict, type FrameGradingVerdict, type Scale } from "./environment"
import type { AppFrame } from "./host"
import {
  afterPaint,
  countNodes,
  describeMutation,
  measureFrameTimes,
  nextFrame,
  recordFrames,
  recordLongWork,
  recordMutations,
  startBusyProbe,
  summarizeLongWork,
  supportsEntryType,
  waitForDom,
  waitFrames,
  type AppWindow,
  type LongWorkSummary,
} from "./probes"
import { classifyInitialScripts, fileName, type ResourceFact } from "./resources"
import {
  busyByWindow,
  busyIntervals,
  busyRate,
  costPerUpdate,
  countByWindow,
  countOver,
  defined,
  frameDeltas,
  framesPerSecond,
  latencyToNextFrame,
  maxOf,
  median,
  paintFrameIndex,
  percentile,
  roundTo,
  sum,
} from "./stats"

export type JourneyName =
  | "warmStart"
  | "switchSqlite"
  | "switchMemory"
  | "send"
  | "typing"
  | "incoming"
  | "streaming"
  | "scrollPaging"
  | "sidebar"
  | "memory"
  | "initialJs"
  | "leaderHandoff"

/** Run order of "run all": reloads first, the memory reading last. */
export const JOURNEYS: readonly JourneyName[] = [
  "warmStart",
  "switchSqlite",
  "switchMemory",
  "send",
  "typing",
  "incoming",
  "streaming",
  "scrollPaging",
  "sidebar",
  "initialJs",
  "leaderHandoff",
  "memory",
]

/** The budget rows each journey owns, so a journey that throws still fills its rows (as errors). */
export const JOURNEY_BUDGETS: Record<JourneyName, readonly BudgetId[]> = {
  warmStart: ["warm-paint", "warm-live"],
  switchSqlite: ["switch-sqlite"],
  switchMemory: ["switch-memory"],
  send: ["send"],
  typing: ["typing-wait", "typing-renders"],
  incoming: ["incoming"],
  streaming: ["stream-20", "stream-40", "stream-60"],
  scrollPaging: ["scroll"],
  sidebar: ["sidebar-scroll", "sidebar-update"],
  memory: ["memory-heap", "memory-dom"],
  initialJs: ["initial-js"],
  leaderHandoff: ["leader-handoff"],
}

export type SampleCounts = {
  warmStarts: number
  sqliteSwitches: number
  memorySwitches: number
  sends: number
  keystrokes: number
  incoming: number
  /** Per rate: the frame pass and the busy-probe pass. */
  streamMeasureMs: number
  streamProbeMs: number
  historyPages: number
  sidebarUpdates: number
}

export const DEFAULT_SAMPLES: SampleCounts = {
  warmStarts: 5,
  sqliteSwitches: 6,
  memorySwitches: 10,
  sends: 5,
  keystrokes: 60,
  incoming: 8,
  streamMeasureMs: 3_000,
  streamProbeMs: 2_000,
  historyPages: 4,
  sidebarUpdates: 4,
}

export type JourneyResult = { rows: ResultRow[]; raw: unknown }

export type JourneyContext = {
  frame: AppFrame
  scale: Scale
  samples: () => SampleCounts
  /** Whether the app frame is on screen (an IntersectionObserver in the page). */
  frameVisible: () => boolean | undefined
  /** The heap reading taken before the journeys of a run. */
  memoryBefore: () => MemoryReading | undefined
  /** DOM size after each journey of this page's runs. */
  domSamples: () => readonly number[]
}

export type MemoryReading = { at: string; usedMB: number | undefined; totalMB: number | undefined; elements: number; nodes: number }

const SWITCH_TIMEOUT_MS = 10_000
const ROW_TIMEOUT_MS = 10_000
/** The draft is saved 300 to 400 ms after the last change; typing's window includes that save. */
const DRAFT_SETTLE_MS = 700
const KEYSTROKE_INTERVAL_MS = 35
const TYPING_TEXT = "the quick brown fox jumps over the lazy dog while the agent keeps typing "
const STREAM_RATES = [20, 40, 60] as const
/** A gap between two busy-probe turns longer than this is time spent elsewhere. */
const BUSY_GAP_MS = 0.5
const BUSY_WINDOW_MS = 250
const SCROLL_STEP_PX = 80
const SCROLL_MAX_FRAMES = 1_500
const SIDEBAR_STEP_PX = 320
const SIDEBAR_MAX_FRAMES = 900
/** The sidebar README: about 30 to 45 rows rendered, whatever the list length. */
const SIDEBAR_ROW_LIMIT = 50
/** Candidate chats for switches: within the rows rendered at the top of the sidebar. */
const CANDIDATE_ROWS = 25

const delay = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms))

const ms = (value: number | undefined) => (value === undefined ? "–" : `${roundTo(value, 1)} ms`)
const extra = (label: string, value: string): Extra => ({ label, value })

const medianWorst = (label: string, values: readonly number[]): Extra =>
  extra(label, values.length === 0 ? "–" : `median ${ms(median(values))}, worst ${ms(maxOf(values))}`)

const longWorkExtras = (summary: LongWorkSummary): Extra[] => {
  const extras: Extra[] = []
  extras.push(
    extra(
      "long tasks",
      summary.longTasks === undefined ? "not reported" : `${summary.longTasks} (longest ${ms(summary.longestTaskMs)})`,
    ),
  )
  extras.push(
    extra(
      "long animation frames",
      summary.longAnimationFrames === undefined
        ? "not supported"
        : `${summary.longAnimationFrames} (longest ${ms(summary.longestFrameMs)})`,
    ),
  )
  if (summary.topScripts.length > 0) {
    extras.push(extra("top scripts", summary.topScripts.slice(0, 3).map((s) => `${s.what} ${s.ms} ms`).join("; ")))
  }
  return extras
}

const FRAME_DELTA_CAVEAT =
  "Frame times are the deltas of a requestAnimationFrame loop in the app's window: they show main-thread frames " +
  "(its own callbacks keep frames coming), not compositor-only frames, and a 120 Hz display halves the base interval."

type SwitchSample = {
  key: string
  chatId: string | undefined
  inputToDom: number
  inputToPaint: number
  paintFrame: number
  hidden: boolean
  empty: boolean
  appSwitchMs: number | undefined
}

export class Journeys {
  #openedLoad = -1
  #opened = new Set<string>()

  constructor(private readonly ctx: JourneyContext) {}

  get frame(): AppFrame {
    return this.ctx.frame
  }

  // -------------------------------------------------------------------------
  // Shared steps

  /** The sidebar keys of chats opened in the frame's current page load (they are, or were, resident). */
  opened(): Set<string> {
    if (this.#openedLoad !== this.frame.loads) {
      this.#openedLoad = this.frame.loads
      this.#opened = new Set()
      const selected = this.frame.selectedSidebarRow()?.dataset.sidebarKey
      if (selected) this.#opened.add(selected)
    }
    return this.#opened
  }

  /** A fresh frame-rate reading of the app's window: frame-time rows are graded only at 30 fps or more. */
  async frameVerdict(): Promise<FrameGradingVerdict & { fps: number | undefined }> {
    const times = await measureFrameTimes(this.frame.win(), 20)
    const fps = framesPerSecond(times)
    return {
      ...frameVerdict({ visibility: document.visibilityState, frameVisible: this.ctx.frameVisible(), fps }),
      fps,
    }
  }

  async scrollSidebarTop(): Promise<void> {
    const scroller = this.frame.sidebarScroller()
    if (scroller && scroller.scrollTop > 0) {
      scroller.scrollTop = 0
      await waitFrames(this.frame.win(), 3, "the sidebar to scroll to the top")
    }
  }

  /** Open the chat of a sidebar row by clicking it, and time it until its rows are painted. */
  async openRow(key: string): Promise<SwitchSample> {
    const frame = this.frame
    let row = frame.sidebarRow(key)
    if (!row) {
      await this.scrollSidebarTop()
      row = frame.sidebarRow(key)
    }
    if (!row) throw new Error(`Sidebar row ${key} is not in the DOM (outside the sidebar's rendered window).`)
    const win = frame.win()
    const doc = frame.doc()
    const old = frame.scroller()
    let hidden = false
    const frames = recordFrames(win)
    try {
      const input = win.performance.now()
      row.click()
      const found = await waitForDom(
        win,
        doc.body,
        () => {
          const scroller = frame.scroller()
          if (!scroller || scroller === old) return undefined
          if (scroller.getAttribute("aria-busy") === "true") {
            hidden = true
            return undefined
          }
          if (frame.keyedRows(frame.timelineContent(scroller)).length > 0) return "rows"
          if (frame.timelineRoot(scroller)?.textContent?.includes("No messages yet")) return "empty"
          return undefined
        },
        `the rows of the chat opened from sidebar row ${key}`,
        SWITCH_TIMEOUT_MS,
        () => `open chat: ${frame.peekApp()?.openChat?.chatId ?? "none"}, list busy: ${frame.scroller()?.getAttribute("aria-busy") ?? "no list"}`,
      )
      const paint = await afterPaint(win)
      frames.stop()
      this.opened().add(key)
      // The app records its own switch measure after its own paint; give it two frames.
      await waitFrames(win, 2)
      const entries = win.performance.getEntriesByName("inline.chat.switch", "measure")
      const last = entries[entries.length - 1]
      return {
        key,
        chatId: frame.peekApp()?.openChat?.chatId,
        inputToDom: found.at - input,
        inputToPaint: paint.paintedAt - input,
        paintFrame: paintFrameIndex(frames.runs, input, found.at),
        hidden,
        empty: found.value === "empty",
        appSwitchMs: last && last.startTime + last.duration > input ? last.duration : undefined,
      }
    } finally {
      frames.stop()
    }
  }

  /** A chat is open with its rows painted; opens the first sidebar chat otherwise. */
  async ensureChatOpen(): Promise<{ key: string; chatId: string }> {
    const frame = this.frame
    const app = frame.app()
    const selected = frame.selectedSidebarRow()?.dataset.sidebarKey
    if (app.openChat && selected && frame.keyedRows().length > 0) return { key: selected, chatId: app.openChat.chatId }
    await this.scrollSidebarTop()
    const first = frame.sidebarRows()[0]?.dataset.sidebarKey
    if (!first) throw new Error("The sidebar has no rows to open.")
    const sample = await this.openRow(first)
    const chatId = sample.chatId ?? frame.app().openChat?.chatId
    if (!chatId) throw new Error("A chat was opened but __inlineApp.openChat is empty.")
    return { key: first, chatId }
  }

  /** Back at the bottom, following latest: click "Jump to latest" when it shows. */
  async followLatest(): Promise<void> {
    const frame = this.frame
    const button = frame.latestButton()
    if (!button) return
    button.click()
    await frame.until(() => frame.latestButton() === null, "the timeline to return to latest", 5_000)
    await waitFrames(frame.win(), 3)
  }

  /** Focus the composer with the caret at the end, and empty it. */
  async composer(): Promise<HTMLElement> {
    const frame = this.frame
    const editor = frame.composerEditor()
    if (!editor) throw new Error("The composer's editor ([role=textbox][contenteditable]) is not in the DOM.")
    editor.focus({ preventScroll: true })
    const selection = frame.win().getSelection()
    selection?.selectAllChildren(editor)
    if ((editor.textContent ?? "").trim() !== "") frame.doc().execCommand("delete")
    selection?.selectAllChildren(editor)
    selection?.collapseToEnd()
    await waitFrames(frame.win(), 2)
    return editor
  }

  async clearComposer(editor: HTMLElement): Promise<void> {
    if ((editor.textContent ?? "").trim() === "") return
    editor.focus({ preventScroll: true })
    this.frame.win().getSelection()?.selectAllChildren(editor)
    this.frame.doc().execCommand("delete")
    await waitFrames(this.frame.win(), 2)
  }

  key(editor: HTMLElement, type: "keydown" | "keyup", key: string): boolean {
    const win = this.frame.win()
    return editor.dispatchEvent(
      new win.KeyboardEvent(type, { key, code: key === "Enter" ? "Enter" : undefined, bubbles: true, cancelable: true }),
    )
  }

  demo(win: AppWindow = this.frame.win()) {
    const demo = win.__inlineDemo
    if (!demo) throw new Error("The app did not expose __inlineDemo: it is not running a demo account.")
    return demo
  }

  // -------------------------------------------------------------------------
  // Warm start

  async warmStart(): Promise<JourneyResult> {
    const frame = this.frame
    await this.ensureChatOpen()
    const names = {
      shell: "inline.boot.shell-paint",
      core: "inline.boot.core-ready",
      sidebar: "inline.boot.sidebar-rows",
      chat: "inline.boot.chat-rows",
      snapshot: "inline.boot.snapshot-paint",
    }
    const read = (win: AppWindow, name: string) => {
      const entry = win.performance.getEntriesByName(name, "measure")[0]
      return entry ? entry.startTime + entry.duration : undefined
    }
    const samples: Record<keyof typeof names, number | undefined>[] = []
    let verdict: FrameGradingVerdict | undefined
    for (let i = 0; i < this.ctx.samples().warmStarts; i++) {
      await frame.reload()
      const required = [names.shell, names.core, names.sidebar, names.chat]
      await frame.until(
        () => required.every((name) => read(frame.win(), name) !== undefined),
        "the boot measures (shell paint, core ready, sidebar rows, chat rows)",
        20_000,
        () => `missing: ${required.filter((name) => read(frame.win(), name) === undefined).join(", ")}`,
      )
      const win = frame.win()
      samples.push({
        shell: read(win, names.shell),
        core: read(win, names.core),
        sidebar: read(win, names.sidebar),
        chat: read(win, names.chat),
        snapshot: read(win, names.snapshot),
      })
      verdict = await this.frameVerdict()
      await delay(300)
    }
    const frames = verdict ?? { allowed: false, reason: "not measured: no frames" }
    const pick = (key: keyof typeof names) => defined(samples.map((s) => s[key]))
    const snapshots = pick("snapshot")
    const hasSnapshot = snapshots.length === samples.length && samples.length > 0
    const painted = hasSnapshot
      ? snapshots
      : defined(samples.map((s) => (s.sidebar !== undefined && s.chat !== undefined ? Math.max(s.sidebar, s.chat) : undefined)))
    const method = "app's performance measures after a reload of the app frame (time origin: the frame's navigation)"
    const rows: ResultRow[] = [
      budgetRow("warmStart", budgetById("warm-paint"), {
        measure: hasSnapshot ? "inline.boot.snapshot-paint" : "later of inline.boot.sidebar-rows and chat-rows",
        method,
        input: "reload",
        samples: painted,
        ...(hasSnapshot
          ? {}
          : {
              caveat:
                "No boot snapshot yet (inline.boot.snapshot-paint absent): measured to the first paint of live sidebar and chat rows, the nearest moment.",
            }),
        extras: [extra("reloads", String(samples.length))],
      }, frames),
      budgetRow("warmStart", budgetById("warm-live"), {
        measure: "inline.boot.core-ready",
        method,
        input: "reload",
        samples: pick("core"),
        caveat: "Core ready is the core's phase, not a check that input is handled; the demo core runs against a simulated server in its worker.",
      }, frames),
      infoRow("warmStart", "warm-paint:shell", "Warm start: shell painted", "ms", {
        measure: "inline.boot.shell-paint",
        method,
        input: "reload",
        samples: pick("shell"),
      }),
      infoRow("warmStart", "warm-paint:sidebar", "Warm start: first sidebar rows painted", "ms", {
        measure: "inline.boot.sidebar-rows",
        method,
        input: "reload",
        samples: pick("sidebar"),
      }),
      infoRow("warmStart", "warm-paint:chat", "Warm start: first chat rows painted", "ms", {
        measure: "inline.boot.chat-rows",
        method,
        input: "reload",
        samples: pick("chat"),
      }),
      infoRow("warmStart", "warm-paint:snapshot", "Warm start: boot snapshot painted", "ms", {
        measure: "inline.boot.snapshot-paint",
        method,
        input: "reload",
        samples: snapshots,
        ...(snapshots.length === 0 ? { notMeasured: "the app does not record inline.boot.snapshot-paint yet" } : {}),
      }),
    ]
    return { rows, raw: { reloads: samples } }
  }

  // -------------------------------------------------------------------------
  // Chat switches

  async switchSqlite(): Promise<JourneyResult> {
    const frame = this.frame
    const target = this.ctx.samples().sqliteSwitches
    const samples: SwitchSample[] = []
    let reloads = 0
    let verdict = await this.frameVerdict()
    while (samples.length < target) {
      await this.scrollSidebarTop()
      const opened = this.opened()
      const candidate = frame
        .sidebarRows()
        .slice(0, CANDIDATE_ROWS)
        .find((row) => row.getAttribute("aria-selected") !== "true" && !opened.has(row.dataset.sidebarKey ?? ""))
      const key = candidate?.dataset.sidebarKey
      if (!key) {
        if (reloads >= target) throw new Error("No chat left that was not opened in this page load, even after reloading.")
        reloads += 1
        await frame.reload()
        // Let the start-up sync settle; a user switches after the window is up, not during boot.
        await waitFrames(frame.win(), 30)
        continue
      }
      samples.push(await this.openRow(key))
      await waitFrames(frame.win(), 10)
    }
    verdict = await this.frameVerdict()
    const hidden = samples.filter((s) => s.hidden).length
    return {
      rows: [
        budgetRow("switchSqlite", budgetById("switch-sqlite"), {
          measure: "click on the sidebar row to the paint after the new chat's rows are in the DOM",
          method: "performance.now() before click(); rows found by a MutationObserver; then a frame and a task",
          input: "synthetic",
          samples: samples.map((s) => s.inputToPaint),
          caveat:
            "Chats not opened in this page load, among the first rows of the sidebar; that their rows are in SQLite is assumed (recent chats the core repaired), not checked.",
          ...(hidden > 0
            ? {
                inconclusive: [
                  `the list was hidden while loading in ${hidden} of ${samples.length} switches: the chat was not in SQLite, or the app did not paint from it; the lab cannot tell which`,
                ],
              }
            : {}),
          extras: [
            extra("paint frame", `median ${median(samples.map((s) => s.paintFrame)) ?? "–"}`),
            medianWorst("click to rows in DOM", samples.map((s) => s.inputToDom)),
            medianWorst("app's inline.chat.switch", defined(samples.map((s) => s.appSwitchMs))),
            extra("hidden while loading", `${hidden} of ${samples.length}`),
            extra("reloads", String(reloads)),
          ],
        }, verdict),
      ],
      raw: { samples, fps: verdict.fps },
    }
  }

  async switchMemory(): Promise<JourneyResult> {
    const frame = this.frame
    const a = await this.ensureChatOpen()
    await this.scrollSidebarTop()
    const b = frame
      .sidebarRows()
      .slice(0, CANDIDATE_ROWS)
      .map((row) => row.dataset.sidebarKey)
      .find((key) => key !== undefined && key !== a.key)
    if (!b) throw new Error("The sidebar needs two chats for a switch.")
    // Warm-up: both chats opened in this page load, so both are resident.
    await this.openRow(b)
    await waitFrames(frame.win(), 5)
    await this.openRow(a.key)
    await waitFrames(frame.win(), 5)
    const verdict = await this.frameVerdict()
    const samples: SwitchSample[] = []
    for (let i = 0; i < this.ctx.samples().memorySwitches; i++) {
      samples.push(await this.openRow(i % 2 === 0 ? b : a.key))
      await waitFrames(frame.win(), 5)
    }
    const hidden = samples.filter((s) => s.hidden).length
    return {
      rows: [
        budgetRow("switchMemory", budgetById("switch-memory"), {
          measure: "the frame after the click that painted the new chat's rows (1 = the next frame)",
          method: "frames counted by a requestAnimationFrame loop between click() and the rows in the DOM (MutationObserver)",
          input: "synthetic",
          samples: samples.map((s) => s.paintFrame),
          checks: [{ ok: hidden === 0, message: `the list was hidden while loading in ${hidden} switches` }],
          caveat:
            "Residency is assumed: both chats were opened in this page load and the app keeps recent chats resident; the app does not say whether a chat was resident.",
          extras: [
            medianWorst("click to paint", samples.map((s) => s.inputToPaint)),
            medianWorst("click to rows in DOM", samples.map((s) => s.inputToDom)),
            medianWorst("app's inline.chat.switch", defined(samples.map((s) => s.appSwitchMs))),
          ],
        }, verdict),
      ],
      raw: { a: a.key, b, samples, fps: verdict.fps },
    }
  }

  // -------------------------------------------------------------------------
  // Send and typing

  async send(): Promise<JourneyResult> {
    const frame = this.frame
    await this.ensureChatOpen()
    await this.followLatest()
    const verdict = await this.frameVerdict()
    const samples: { inputToDom: number; inputToPaint: number; paintFrame: number; cleared: number | undefined }[] = []
    for (let i = 0; i < this.ctx.samples().sends; i++) {
      const editor = await this.composer()
      const token = `perf-lab send ${Date.now().toString(36)} ${i + 1}`
      frame.doc().execCommand("insertText", false, token)
      await waitFrames(frame.win(), 2)
      if (!(editor.textContent ?? "").includes(token)) throw new Error("The composer did not take the inserted text.")
      const win = frame.win()
      const root = frame.timelineRoot()
      if (!root) throw new Error("No message list on screen.")
      const frames = recordFrames(win)
      try {
        const input = win.performance.now()
        this.key(editor, "keydown", "Enter")
        const found = await waitForDom(
          win,
          root,
          () => frame.keyedRows().slice(-5).some((row) => (row.textContent ?? "").includes(token)),
          `the sent row "${token}" in the message list`,
          ROW_TIMEOUT_MS,
        )
        const paint = await afterPaint(win)
        frames.stop()
        this.key(editor, "keyup", "Enter")
        let cleared: number | undefined
        try {
          await frame.until(() => (editor.textContent ?? "").trim() === "", "the composer to clear after the send", 5_000)
          cleared = win.performance.now() - input
        } catch {
          cleared = undefined
        }
        samples.push({
          inputToDom: found.at - input,
          inputToPaint: paint.paintedAt - input,
          paintFrame: paintFrameIndex(frames.runs, input, found.at),
          cleared,
        })
      } finally {
        frames.stop()
      }
      await waitFrames(win, 5)
    }
    const uncleared = samples.filter((s) => s.cleared === undefined).length
    return {
      rows: [
        budgetRow("send", budgetById("send"), {
          measure: "the frame after the Enter keydown that painted the sent row (1 = the next frame)",
          method: "frames counted between the keydown dispatch and the row in the DOM (MutationObserver)",
          input: "synthetic",
          samples: samples.map((s) => s.paintFrame),
          caveat: "Text inserted with execCommand, Enter dispatched as an untrusted keydown on the editor; real key events add the browser's own input latency.",
          extras: [
            medianWorst("keydown to paint", samples.map((s) => s.inputToPaint)),
            medianWorst("keydown to row in DOM", samples.map((s) => s.inputToDom)),
            medianWorst("keydown to composer cleared (durable commit)", defined(samples.map((s) => s.cleared))),
            ...(uncleared > 0 ? [extra("composer not cleared", `${uncleared} of ${samples.length}`)] : []),
          ],
        }, verdict),
      ],
      raw: { samples, fps: verdict.fps },
    }
  }

  async typing(): Promise<JourneyResult> {
    const frame = this.frame
    await this.ensureChatOpen()
    const editor = await this.composer()
    const win = frame.win()
    const root = frame.timelineRoot()
    if (!root) throw new Error("No message list on screen.")
    const count = this.ctx.samples().keystrokes
    const mutations = recordMutations(win, root)
    const work = recordLongWork(win)
    const frames = recordFrames(win)
    const keystrokes: { at: number; handlerMs: number }[] = []
    try {
      for (let i = 0; i < count; i++) {
        const ch = TYPING_TEXT[i % TYPING_TEXT.length] as string
        const at = win.performance.now()
        this.key(editor, "keydown", ch)
        frame.doc().execCommand("insertText", false, ch)
        this.key(editor, "keyup", ch)
        keystrokes.push({ at, handlerMs: win.performance.now() - at })
        await delay(KEYSTROKE_INTERVAL_MS)
      }
      await delay(DRAFT_SETTLE_MS)
    } finally {
      frames.stop()
    }
    const recorded = work.stop()
    const batches = mutations.stop()
    const typed = (editor.textContent ?? "").length
    await this.clearComposer(editor)
    await delay(DRAFT_SETTLE_MS)
    const summary = summarizeLongWork(recorded, { tasks: work.tasks.supported, frames: work.frames.supported })
    const records = batches.flatMap((batch) => batch.records)
    const latencies = defined(latencyToNextFrame(keystrokes.map((k) => k.at), frames.runs))
    const handler = keystrokes.map((k) => k.handlerMs)
    const method = `${count} keystrokes ${KEYSTROKE_INTERVAL_MS} ms apart, then ${DRAFT_SETTLE_MS} ms for the draft save`
    return {
      rows: [
        budgetRow("typing", budgetById("typing-wait"), {
          measure: "long tasks (50 ms or more) while typing and saving the draft",
          method: `PerformanceObserver longtask; ${method}`,
          input: "synthetic",
          samples: summary.longTasks === undefined ? [] : [summary.longTasks],
          ...(summary.longTasks === undefined ? { notMeasured: "long tasks are not reported by this browser" } : {}),
          caveat:
            "Store work runs in the worker; a keystroke that waited on it would show as a slow handler or a long task. Shorter stalls show in the handler and next-frame times.",
          extras: [
            medianWorst("keystroke handling (sync)", handler),
            medianWorst("keystroke to next frame", latencies),
            ...longWorkExtras(summary),
            ...(typed < count ? [extra("characters in the composer", `${typed} of ${count}`)] : []),
          ],
        }, { allowed: true }),
        budgetRow("typing", budgetById("typing-renders"), {
          measure: "DOM mutations under the message list while typing and saving the draft",
          method: `MutationObserver on the timeline root; ${method}`,
          input: "synthetic",
          samples: [records.length],
          caveat:
            "A proxy for renders: a render that commits no DOM change is not seen. Exact counts need the render counter inside the app.",
          extras: records.length > 0 ? [extra("first", records.slice(0, 3).map(describeMutation).join("; "))] : [],
        }, { allowed: true }),
      ],
      raw: { keystrokes, latencies, longWork: summary, mutations: records.slice(0, 20).map(describeMutation) },
    }
  }

  // -------------------------------------------------------------------------
  // Incoming and streaming

  async incoming(): Promise<JourneyResult> {
    const frame = this.frame
    const { chatId } = await this.ensureChatOpen()
    await this.followLatest()
    const verdict = await this.frameVerdict()
    const prefix = `m:${chatId}:`
    const samples: { sendToAck: number; ackToDom: number; ackToPaint: number; paintFrame: number }[] = []
    for (let i = 0; i < this.ctx.samples().incoming; i++) {
      const win = frame.win()
      const content = frame.timelineContent()
      if (!content) throw new Error("No message list on screen.")
      const before = new Set(frame.keyedRows(content).map((row) => row.dataset.timelineKey))
      const seen = new Map<string, number>()
      const observer = new win.MutationObserver(() => {
        const now = win.performance.now()
        for (const row of frame.keyedRows(content)) {
          const key = row.dataset.timelineKey
          if (key && key.startsWith(prefix) && !before.has(key) && !seen.has(key)) seen.set(key, now)
        }
      })
      observer.observe(content, { childList: true })
      const frames = recordFrames(win)
      try {
        const sent = win.performance.now()
        const result = await this.demo(win).send({ kind: "deliver", chatId })
        const ack = win.performance.now()
        if (!result.ok) throw new Error(`The demo did not deliver: ${result.error ?? "no reason"}`)
        const expected = result.detail?.messageId ? `${prefix}${result.detail.messageId}` : undefined
        const found = await waitForDom(
          win,
          content,
          () => (expected ? seen.has(expected) || content.querySelector(`[data-timeline-key="${CSS.escape(expected)}"]`) !== null : seen.size > 0),
          `the delivered message ${expected ?? "(no ID in the result)"} in the open chat`,
          ROW_TIMEOUT_MS,
        )
        const domAt = (expected ? seen.get(expected) : [...seen.values()][0]) ?? found.at
        const paint = await afterPaint(win)
        frames.stop()
        samples.push({
          sendToAck: ack - sent,
          ackToDom: domAt - ack,
          ackToPaint: paint.paintedAt - ack,
          paintFrame: paintFrameIndex(frames.runs, ack, domAt),
        })
      } finally {
        observer.disconnect()
        frames.stop()
      }
      await waitFrames(win, 8)
    }
    return {
      rows: [
        budgetRow("incoming", budgetById("incoming"), {
          measure: "the frame after the demo's acknowledgement that painted the delivered row",
          method: "deliver through __inlineDemo; frames counted from the result to the row in the DOM (MutationObserver)",
          input: "handle",
          samples: samples.map((s) => s.paintFrame),
          caveat:
            "The patch's arrival is not observable from outside, so the clock starts at the demo's result, which travels beside the patch (BroadcastChannel versus the core's port); one frame of allowance is added for that.",
          extras: [
            medianWorst("result to paint", samples.map((s) => s.ackToPaint)),
            medianWorst("result to row in DOM (negative: row first)", samples.map((s) => s.ackToDom)),
            medianWorst("command to result (control overhead)", samples.map((s) => s.sendToAck)),
          ],
        }, verdict),
      ],
      raw: { samples, fps: verdict.fps },
    }
  }

  /** Start the agent in the open chat and wait for its row; returns the row's key and element. */
  async startAgent(chatId: string, rate: number, durationMs: number): Promise<{ key: string; row: HTMLElement }> {
    const frame = this.frame
    const win = frame.win()
    const content = frame.timelineContent()
    if (!content) throw new Error("No message list on screen.")
    const prefix = `m:${chatId}:`
    const before = new Set(frame.keyedRows(content).map((row) => row.dataset.timelineKey))
    const result = await this.demo(win).send({ kind: "agent", action: "start", chatId, updatesPerSecond: rate, durationMs })
    if (!result.ok) throw new Error(`The demo agent did not start: ${result.error ?? "no reason"}`)
    const expected = result.detail?.messageId ? `${prefix}${result.detail.messageId}` : undefined
    const { value } = await waitForDom(
      win,
      content,
      () =>
        frame
          .keyedRows(content)
          .find((row) =>
            expected ? row.dataset.timelineKey === expected : row.dataset.timelineKey?.startsWith(prefix) && !before.has(row.dataset.timelineKey),
          ),
      `the agent's message row at ${rate} updates a second`,
      ROW_TIMEOUT_MS,
    )
    return { key: value.dataset.timelineKey ?? "", row: value }
  }

  async stopAgent(): Promise<void> {
    const result = await this.demo().send({ kind: "agent", action: "stop" })
    if (!result.ok) throw new Error(`The demo agent did not stop: ${result.error ?? "no reason"}`)
    await waitFrames(this.frame.win(), 20)
  }

  async streaming(): Promise<JourneyResult> {
    const frame = this.frame
    const { chatId } = await this.ensureChatOpen()
    await this.followLatest()
    const { streamMeasureMs, streamProbeMs } = this.ctx.samples()
    const win0 = frame.win()

    // Baseline for the busy probe: the same probe with nothing streaming.
    const baselineProbe = startBusyProbe(win0)
    await delay(streamProbeMs)
    const baselineRate = busyRate(baselineProbe.stop(), BUSY_GAP_MS)

    const rows: ResultRow[] = []
    const raw: Record<string, unknown> = { baselineBusyPerSecondMs: roundTo(baselineRate * 1000, 1) }
    for (const rate of STREAM_RATES) {
      const verdict = await this.frameVerdict()
      const win = frame.win()
      const root = frame.timelineRoot()
      if (!root) throw new Error("No message list on screen.")

      // Pass 1: frames, long work and mutations outside the streaming row.
      const first = await this.startAgent(chatId, rate, streamMeasureMs + 2_000)
      const editsBefore = this.demo(win).status.peek()?.agent?.edits ?? 0
      const mutations = recordMutations(win, root)
      const work = recordLongWork(win)
      const frames = recordFrames(win)
      const started = win.performance.now()
      await delay(streamMeasureMs)
      frames.stop()
      const elapsed = win.performance.now() - started
      const recorded = work.stop()
      const batches = mutations.stop()
      const editsAfter = this.demo(win).status.peek()?.agent?.edits ?? editsBefore
      await this.stopAgent()
      const streamingRow = frame.keyedRows().find((row) => row.dataset.timelineKey === first.key) ?? first.row
      const outside: MutationRecord[] = []
      let rowUpdates = 0
      let inside = 0
      for (const batch of batches) {
        let touched = false
        for (const record of batch.records) {
          if (streamingRow.contains(record.target)) {
            touched = true
            inside += 1
          } else {
            outside.push(record)
          }
        }
        if (touched) rowUpdates += 1
      }
      const deltas = frameDeltas(frames.frames)
      const summary = summarizeLongWork(recorded, { tasks: work.tasks.supported, frames: work.frames.supported })

      // Pass 2: the busy probe, with the stream running again (a new agent message).
      const second = await this.startAgent(chatId, rate, streamProbeMs + 2_000)
      const rowMutations = recordMutations(win, second.row)
      const probe = startBusyProbe(win)
      const probeStart = win.performance.now()
      await delay(streamProbeMs)
      const ticks = probe.stop()
      const updates = rowMutations.stop().map((batch) => batch.at)
      await this.stopAgent()
      const windows = Math.floor(streamProbeMs / BUSY_WINDOW_MS)
      const busy = busyByWindow(busyIntervals(ticks, BUSY_GAP_MS), probeStart, BUSY_WINDOW_MS, windows)
      const costs = costPerUpdate(busy, countByWindow(updates, probeStart, BUSY_WINDOW_MS, windows), BUSY_WINDOW_MS, baselineRate)

      rows.push(
        budgetRow("streaming", budgetById(`stream-${rate}`), {
          measure: "main-thread time per row update, per 250 ms window (an upper bound on scripting)",
          method:
            "busy probe (self-posting MessageChannel loop: gaps over 0.5 ms are other work) minus an idle baseline, divided by the row's DOM updates",
          input: "handle",
          samples: costs,
          upperBound: true,
          checks: [
            {
              ok: outside.length === 0,
              message: `${outside.length} DOM mutations outside the streaming row (${outside.slice(0, 3).map(describeMutation).join("; ")})`,
            },
          ],
          caveat:
            "Scripting per update is not observable from outside: the probe counts style, layout and paint too, so over 4 ms is inconclusive, not a failure. Frames, long work and mutations come from a separate pass without the probe.",
          extras: [
            extra("frames over 32 ms", `${countOver(deltas, 32)} of ${deltas.length}`),
            extra("frame time", `median ${ms(median(deltas))}, p95 ${ms(percentile(deltas, 95))}, worst ${ms(maxOf(deltas))}`),
            extra("row DOM updates", `${roundTo((rowUpdates * 1000) / elapsed, 1)}/s`),
            extra("edits sent", `${roundTo(((editsAfter - editsBefore) * 1000) / elapsed, 1)}/s (status, approximate)`),
            extra("mutations inside the row per update", rowUpdates === 0 ? "–" : String(roundTo(inside / rowUpdates, 1))),
            ...longWorkExtras(summary),
          ],
        }, verdict),
      )
      raw[`rate${rate}`] = {
        fps: verdict.fps,
        frameDeltas: deltas.map((d) => roundTo(d, 2)),
        rowUpdates,
        edits: editsAfter - editsBefore,
        outside: outside.slice(0, 20).map(describeMutation),
        longWork: summary,
        busyByWindow: busy.map((b) => roundTo(b, 2)),
        costs: costs.map((c) => roundTo(c, 3)),
      }
    }
    return { rows, raw }
  }

  // -------------------------------------------------------------------------
  // Scrolling

  async scrollPaging(): Promise<JourneyResult> {
    const frame = this.frame
    await this.ensureChatOpen()
    const target = this.ctx.samples().historyPages
    const verdict = await this.frameVerdict()
    const deltas: number[] = []
    const attempts: { chat: string | undefined; pages: number; frames: number; reachedTop: boolean }[] = []
    let summary: LongWorkSummary | undefined
    const tried = new Set<string>()
    for (let attempt = 0; attempt < 3; attempt++) {
      const win = frame.win()
      const scroller = frame.scroller()
      const content = frame.timelineContent(scroller)
      if (!scroller || !content) throw new Error("No message list on screen.")
      tried.add(frame.selectedSidebarRow()?.dataset.sidebarKey ?? "")
      const known = new Set(frame.keyedRows(content).map((row) => row.dataset.timelineKey))
      let pages = 0
      let atTop = 0
      let steps = 0
      const work = recordLongWork(win)
      const frames = recordFrames(win)
      try {
        while (steps < SCROLL_MAX_FRAMES) {
          await nextFrame(win, "scrolling the message list")
          steps += 1
          // A new key at the head is a page of history arriving.
          let added = false
          for (const row of frame.keyedRows(content)) {
            const key = row.dataset.timelineKey
            if (!key || known.has(key)) break
            known.add(key)
            added = true
          }
          if (added) pages += 1
          if (pages >= target) break
          if (scroller.scrollTop <= 0) {
            atTop += 1
            if (atTop > 90) break
          } else {
            atTop = 0
          }
          scroller.dispatchEvent(new win.WheelEvent("wheel", { deltaY: -SCROLL_STEP_PX, bubbles: true, cancelable: true }))
          scroller.scrollTop -= SCROLL_STEP_PX
        }
      } finally {
        frames.stop()
      }
      const recorded = work.stop()
      summary = summarizeLongWork(recorded, { tasks: work.tasks.supported, frames: work.frames.supported })
      deltas.push(...frameDeltas(frames.frames))
      attempts.push({ chat: frame.peekApp()?.openChat?.chatId, pages, frames: steps, reachedTop: atTop > 90 })
      await this.followLatest()
      if (pages >= Math.min(2, target)) break
      // Too little history here: try another recent chat.
      await this.scrollSidebarTop()
      const next = frame
        .sidebarRows()
        .slice(0, CANDIDATE_ROWS)
        .map((row) => row.dataset.sidebarKey)
        .find((key) => key !== undefined && !tried.has(key))
      if (!next) break
      await this.openRow(next)
      await waitFrames(frame.win(), 10)
    }
    const pages = sum(attempts.map((a) => a.pages))
    return {
      rows: [
        budgetRow("scrollPaging", budgetById("scroll"), {
          measure: `frame times while scrolling up ${SCROLL_STEP_PX} px a frame through history`,
          method: "requestAnimationFrame deltas; each frame a synthetic wheel then the scroll offset write (the user's stand-in)",
          input: "synthetic",
          samples: deltas,
          ...(pages === 0 ? { inconclusive: ["no page of history arrived: every chat tried fit in its window"] } : {}),
          caveat: `${FRAME_DELTA_CAVEAT} No momentum and no compositor scrolling. Anchor drift is the timeline lab's measure.`,
          extras: [
            extra("pages of history", `${pages} in ${attempts.length} chat(s)`),
            extra("frames over 32 ms", `${countOver(deltas, 32)} of ${deltas.length}`),
            extra("frame time", `median ${ms(median(deltas))}, p95 ${ms(percentile(deltas, 95))}`),
            ...(summary ? longWorkExtras(summary) : []),
          ],
        }, verdict),
      ],
      raw: { attempts, frameDeltas: deltas.map((d) => roundTo(d, 2)), longWork: summary },
    }
  }

  // -------------------------------------------------------------------------
  // Sidebar

  async sidebar(): Promise<JourneyResult> {
    const frame = this.frame
    const scale = this.ctx.scale
    const scaleNote = scale === "large" ? [] : [`measured at the ${scale} scale; the budget is for large (?scale=large)`]
    let verdict = await this.frameVerdict()

    // Scroll the whole list.
    const scroller = frame.sidebarScroller()
    if (!scroller) throw new Error("The sidebar does not scroll (too few chats for the window?).")
    const win = frame.win()
    scroller.scrollTop = 0
    await waitFrames(win, 3)
    const setSize = Number(frame.sidebarRows()[0]?.getAttribute("aria-setsize") ?? 0)
    let maxRows = 0
    let steps = 0
    let atBottom = 0
    const work = recordLongWork(win)
    const frames = recordFrames(win)
    try {
      while (steps < SIDEBAR_MAX_FRAMES) {
        await nextFrame(win, "scrolling the sidebar")
        steps += 1
        maxRows = Math.max(maxRows, frame.doc().querySelectorAll("[data-sidebar-key]").length)
        if (scroller.scrollTop + scroller.clientHeight >= scroller.scrollHeight - 1) {
          atBottom += 1
          if (atBottom > 10) break
        }
        scroller.scrollTop += SIDEBAR_STEP_PX
      }
    } finally {
      frames.stop()
    }
    const summary = summarizeLongWork(work.stop(), { tasks: work.tasks.supported, frames: work.frames.supported })
    const deltas = frameDeltas(frames.frames)
    scroller.scrollTop = 0
    await waitFrames(win, 5)

    // Update one chat: deliver to the open chat once (it moves to the top), then measure deliveries to it.
    const { chatId } = await this.ensureChatOpen()
    const warm = await this.demo().send({ kind: "deliver", chatId })
    if (!warm.ok) throw new Error(`The demo did not deliver: ${warm.error ?? "no reason"}`)
    await waitFrames(frame.win(), 20)
    verdict = verdict.allowed ? verdict : await this.frameVerdict()
    const updates: { rowsTouched: number; other: number; ackToRow: number; reordered: boolean }[] = []
    for (let i = 0; i < this.ctx.samples().sidebarUpdates; i++) {
      const w = frame.win()
      const listbox = frame.sidebarListbox()
      const row = frame.selectedSidebarRow()
      if (!listbox || !row) throw new Error("The open chat's sidebar row is not in the DOM.")
      const reordered = row.getAttribute("aria-posinset") !== "1"
      const mutations = recordMutations(w, listbox)
      const result = await this.demo(w).send({ kind: "deliver", chatId })
      const ack = w.performance.now()
      if (!result.ok) throw new Error(`The demo did not deliver: ${result.error ?? "no reason"}`)
      const touchedRow = () => mutations.batches.find((batch) => batch.records.some((r) => row.contains(r.target)))
      await waitForDom(w, listbox, () => touchedRow() !== undefined, "the open chat's sidebar row to change after a delivery", ROW_TIMEOUT_MS)
      const ackToRow = (touchedRow()?.at ?? ack) - ack
      // Follow-up changes (read state) belong to the same update.
      await waitFrames(w, 15)
      const records = mutations.stop().flatMap((batch) => batch.records)
      const keys = new Set<string>()
      let other = 0
      for (const record of records) {
        const element = record.target.nodeType === 1 ? (record.target as Element) : record.target.parentElement
        const key = element?.closest("[data-sidebar-key]")?.getAttribute("data-sidebar-key")
        if (key) keys.add(key)
        else other += 1
      }
      updates.push({ rowsTouched: keys.size, other, ackToRow, reordered })
      await waitFrames(w, 5)
    }
    const reorders = updates.filter((u) => u.reordered).length
    const rows: ResultRow[] = [
      budgetRow("sidebar", budgetById("sidebar-scroll"), {
        measure: `frame times scrolling the whole list ${SIDEBAR_STEP_PX} px a frame`,
        method: "requestAnimationFrame deltas; the scroll offset written each frame",
        input: "synthetic",
        samples: deltas,
        checks: [{ ok: maxRows <= SIDEBAR_ROW_LIMIT, message: `${maxRows} rows in the DOM (window limit ${SIDEBAR_ROW_LIMIT})` }],
        ...(scaleNote.length > 0 ? { inconclusive: scaleNote } : {}),
        caveat: FRAME_DELTA_CAVEAT,
        extras: [
          extra("chats in the list", String(setSize)),
          extra("most rows in the DOM", String(maxRows)),
          extra("frames over 32 ms", `${countOver(deltas, 32)} of ${deltas.length}`),
          extra("frame time", `median ${ms(median(deltas))}, p95 ${ms(percentile(deltas, 95))}`),
          ...longWorkExtras(summary),
        ],
      }, verdict),
      budgetRow("sidebar", budgetById("sidebar-update"), {
        measure: "sidebar rows with DOM mutations after one incoming message to the top chat",
        method: "deliver through __inlineDemo to the open chat (already at the top); MutationObserver on the listbox for 15 frames",
        input: "handle",
        samples: updates.map((u) => u.rowsTouched),
        ...(scaleNote.length > 0 || reorders > 0
          ? {
              inconclusive: [
                ...scaleNote,
                ...(reorders > 0 ? [`the chat was not at the top in ${reorders} updates, so rows moved`] : []),
              ],
            }
          : {}),
        caveat: "DOM mutations stand in for renders. The open chat is used, so it is read at once; an unread chat also changes its badge.",
        extras: [
          medianWorst("result to row changed", updates.map((u) => u.ackToRow)),
          extra("mutations outside rows", String(sum(updates.map((u) => u.other)))),
        ],
      }, { allowed: true }),
    ]
    return { rows, raw: { setSize, maxRows, frameDeltas: deltas.map((d) => roundTo(d, 2)), longWork: summary, updates } }
  }

  // -------------------------------------------------------------------------
  // Memory, bundle, handoff

  readMemory(): MemoryReading {
    const win = this.frame.win()
    const memory = (win.performance as Performance & { memory?: { usedJSHeapSize: number; totalJSHeapSize: number } }).memory
    const { elements, nodes } = countNodes(this.frame.doc())
    return {
      at: new Date().toISOString(),
      usedMB: memory ? memory.usedJSHeapSize / 1_048_576 : undefined,
      totalMB: memory ? memory.totalJSHeapSize / 1_048_576 : undefined,
      elements,
      nodes,
    }
  }

  async memory(): Promise<JourneyResult> {
    // Let pending work and a minor collection happen before reading.
    await delay(500)
    const after = this.readMemory()
    const before = this.ctx.memoryBefore()
    const domSamples = [...this.ctx.domSamples(), after.elements]
    return {
      rows: [
        budgetRow("memory", budgetById("memory-heap"), {
          measure: "used JS heap after the journeys",
          method: "performance.memory.usedJSHeapSize of the app frame (non-standard, Chromium only)",
          input: "passive",
          samples: after.usedMB === undefined ? [] : [after.usedMB],
          ...(after.usedMB === undefined ? { notMeasured: "performance.memory is not available in this browser" } : {}),
          caveat:
            "Minutes of scripted use, not a working day. The frame shares the lab's heap (same agent), so the lab's own objects are included; Chromium quantizes the value.",
          extras: [
            extra("before the journeys", before?.usedMB === undefined ? "–" : `${roundTo(before.usedMB, 1)} MB`),
            extra("total heap", after.totalMB === undefined ? "–" : `${roundTo(after.totalMB, 1)} MB`),
          ],
        }, { allowed: true }),
        budgetRow("memory", budgetById("memory-dom"), {
          measure: "elements in the app's document, after each journey (worst)",
          method: "getElementsByTagName('*') on the app frame's document",
          input: "passive",
          samples: domSamples,
          caveat: "Counts elements; all nodes (text included) are in the extras.",
          extras: [extra("all nodes now", String(after.nodes))],
        }, { allowed: true }),
      ],
      raw: { before, after, domSamples },
    }
  }

  async initialJs(): Promise<JourneyResult> {
    const win = this.frame.win()
    const shell = win.performance.getEntriesByName("inline.boot.shell-paint", "measure")[0]
    if (!shell) throw new Error("No inline.boot.shell-paint measure in this page load of the app.")
    const shellAt = shell.startTime + shell.duration
    const facts: ResourceFact[] = (win.performance.getEntriesByType("resource") as PerformanceResourceTiming[]).map((entry) => ({
      name: entry.name,
      initiatorType: entry.initiatorType,
      startTime: entry.startTime,
      transferSize: entry.transferSize,
      encodedBodySize: entry.encodedBodySize,
      decodedBodySize: entry.decodedBodySize,
    }))
    const { counted, excluded } = classifyInitialScripts(facts, shellAt, win.location.origin)
    const canGzip = typeof CompressionStream === "function"
    const files: { file: string; transfer: number; encoded: number; decoded: number; gzip: number | undefined }[] = []
    for (const entry of counted) {
      let gzip: number | undefined
      if (canGzip) {
        try {
          const response = await fetch(entry.name, { cache: "force-cache" })
          const body = response.body
          if (body) gzip = (await new Response(body.pipeThrough(new CompressionStream("gzip"))).arrayBuffer()).byteLength
        } catch {
          gzip = undefined
        }
      }
      files.push({
        file: fileName(entry.name),
        transfer: entry.transferSize,
        encoded: entry.encodedBodySize,
        decoded: entry.decodedBodySize,
        gzip,
      })
    }
    const missing = files.filter((f) => f.gzip === undefined).length
    const kb = (bytes: number) => bytes / 1_000
    const gzipTotal = sum(files.map((f) => f.gzip ?? f.encoded))
    const doubts = [
      ...(missing > 0 ? [`${missing} files could not be gzipped here; their encoded size is used`] : []),
      ...(facts.length >= 250 ? ["the resource timing buffer is full (250 entries): scripts may be missing"] : []),
    ]
    return {
      rows: [
        budgetRow("initialJs", budgetById("initial-js"), {
          measure: "gzip size of the scripts fetched before the shell painted",
          method: "resource timing of the app frame up to inline.boot.shell-paint; each script fetched again and gzipped in the browser",
          input: "passive",
          samples: files.length === 0 ? [] : [kb(gzipTotal)],
          caveat:
            "gzip computed with CompressionStream (the preview server does not compress); production may serve brotli, which is smaller. Workers, the SQLite WASM and demo or labs-only chunks are excluded (raw data lists them). KB is 1,000 bytes.",
          ...(doubts.length > 0 ? { inconclusive: doubts } : {}),
          extras: [
            extra("files", String(files.length)),
            extra("decoded", `${roundTo(kb(sum(files.map((f) => f.decoded))), 1)} KB`),
            extra("as served (encoded)", `${roundTo(kb(sum(files.map((f) => f.encoded))), 1)} KB`),
            extra("shell painted at", ms(shellAt)),
          ],
        }, { allowed: true }),
      ],
      raw: { shellAt, files, excluded },
    }
  }

  async leaderHandoff(): Promise<JourneyResult> {
    return {
      rows: [
        budgetRow("leaderHandoff", budgetById("leader-handoff"), {
          measure: "",
          method: "",
          input: "passive",
          samples: [],
          notMeasured:
            "needs a second tab and closing the leader with a send in flight; a single page cannot do it honestly (app README check 12 by hand)",
        }, { allowed: true }),
      ],
      raw: null,
    }
  }

  /** Frame-time support facts for the environment. */
  supports(win: AppWindow) {
    return {
      longtask: supportsEntryType(win, "longtask"),
      longAnimationFrame: supportsEntryType(win, "long-animation-frame"),
      eventTiming: supportsEntryType(win, "event"),
      memory: "memory" in win.performance,
      compressionStream: typeof CompressionStream === "function",
    }
  }
}
