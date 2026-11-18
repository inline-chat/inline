/**
 * The timeline lab's operations and the measurements around them. Each
 * operation puts the list in a known state, acts, waits for the frames it
 * needs, and records one result row (see `results.ts`):
 *
 * - drift: the controller's reference row (its first surviving anchor)
 *   measured with `getBoundingClientRect` relative to the container's top,
 *   in CSS (device-independent) pixels, sampled at the start of every frame
 *   after the operation, so a wrong position that was painted for one frame
 *   counts even when a later frame corrects it;
 * - the controller's mode before and after;
 * - renders of the timeline's list and row components and of the lab's rows
 *   (the render-count harness of `@inline/reactive/react/testing`).
 *
 * The lab measures; the view never does. The lab's only scroll writes stand
 * in for the user: each follows a synthetic wheel event on the container, so
 * the DOM host reports user input first, as for a real wheel.
 *
 * Operations wait for animation frames, never for wall-clock time (except
 * the simulated network delay), and fail with a clear error when frames
 * stop (an occluded window).
 */

import { messageId, type MessageID } from "@inline/ids"
import type { ItemKey, TimelineMode } from "@inline/timeline"
import { centeredOffset, TRIM_TO_ROWS } from "@inline/timeline"
import { FrameTimeoutError } from "./frames"
import { createRandom, type Random } from "./generate"
import type { TimelineLab } from "./lab"
import { DEFAULT_FRAME } from "./lab"
import { failedResult, summarize, type Check, type Metric, type OpResult, type RepMeasure } from "./results"

/** One point of a traced repetition. Offsets are relative to the container's top, px. */
export type TraceState = {
  /** The controller's reference row at this point. */
  reference: ItemKey | null
  /** Offset of the row measured for drift (the reference before the operation). */
  anchorTop: number | null
  /** The changed row's top and height, and its media box's height. */
  rowTop: number | null
  rowHeight: number | null
  boxHeight: number | null
  scrollTop: number
  scrollHeight: number
  offsets: { intended: number; last: number; phase: number }
}

export type TraceEntry = {
  anchorKey: ItemKey
  rowKey: ItemKey
  /** States by point: "before", "armed" (late media armed by the lab), "after". */
  states: Record<string, TraceState>
  drift: RepMeasure | null
  /** Whether the controller's reference row is the same before and after. */
  sameAnchor: boolean | null
  [extra: string]: unknown
}

type Body = () => Promise<{ metric: Metric; reps: RepMeasure[]; checks?: Check[]; notes?: string[] }>

/** One run of "run all": 100 repetitions for prepend and resize, fewer where each one is slow. */
export const REPETITIONS = {
  prepend: 100,
  resize: 100,
  lateMedia: 20,
  append: 5,
  streamFrames: 60,
}

/** Rows loaded for the prepend and trim runs: all of them render, so the head of the window is on the page. */
const HEAD_ROWS = 50

const STREAM_WORDS = "and then the agent wrote another line about the timeline while streaming tokens".split(" ")

export const createOperations = (lab: TimelineLab) => {
  const { controller, core, surface, waiter, counter } = lab

  // ---------------------------------------------------------------------------
  // Reading the DOM (the lab measures; the view never does)

  const container = (): HTMLElement => {
    const element = surface.element()
    if (!element) throw new Error("The timeline is not mounted.")
    return element
  }

  const rowElement = (key: ItemKey): HTMLElement | null =>
    container().querySelector<HTMLElement>(`[data-timeline-key="${CSS.escape(key)}"]`)

  const containerTop = () => {
    const box = container()
    return box.getBoundingClientRect().top + box.clientTop
  }

  const topOf = (key: ItemKey): number | undefined => {
    const element = rowElement(key)
    return element ? element.getBoundingClientRect().top - containerTop() : undefined
  }

  const rectOf = (key: ItemKey) => {
    const element = rowElement(key)
    if (!element) return undefined
    const top = containerTop()
    const rect = element.getBoundingClientRect()
    return { top: rect.top - top, bottom: rect.bottom - top }
  }

  const bottomGap = () => {
    const box = container()
    return Math.max(0, box.scrollHeight - box.clientHeight - box.scrollTop)
  }

  const viewportHeight = () => container().clientHeight

  const messageKeys = () => surface.keys.peek().filter((key) => key.startsWith("m:"))

  /** The controller's reference row: its first anchor still in the DOM. */
  const anchorProbe = () => {
    const key = controller.debug().anchors.find((anchor) => rowElement(anchor.key))?.key
    if (!key) throw new Error("The controller has no anchored row on screen.")
    return {
      key,
      probe: () => {
        const top = topOf(key)
        if (top === undefined) throw new Error(`The anchored row ${key} left the DOM.`)
        return top
      },
    }
  }

  const renders = () => ({
    list: counter.count("timeline:list"),
    rows: counter.count("timeline:row"),
    labRows: counter.count("lab:row"),
  })

  // ---------------------------------------------------------------------------
  // Driving

  const settled = () => {
    const debug = controller.debug()
    return !debug.userScrolling && !debug.animating && debug.jump === null && debug.placement === null && !controller.hidden.peek()
  }

  const settle = (what: string) => waiter.until(settled, what)

  /** A wheel event (the host reports user input), then the scroll the browser would perform for it. */
  const userScrollBy = async (dy: number) => {
    const box = container()
    box.dispatchEvent(new WheelEvent("wheel", { deltaY: dy, bubbles: true, cancelable: true }))
    box.scrollTop += dy
    await waiter.frames(2, undefined, "User scroll")
  }

  /**
   * Measure `probe` around `action`: once at the start of a frame, then at the
   * start of each of `frames` frames. `hooks` run where "before" and the final
   * value are read (for traces).
   */
  const measure = async (
    probe: () => number,
    action: () => unknown,
    frames = 2,
    hooks: { before?: () => void; after?: () => void } = {},
  ): Promise<RepMeasure> => {
    await waiter.nextFrame("Before the operation")
    const before = probe()
    hooks.before?.()
    await action()
    let maxAbs = 0
    await waiter.frames(frames, () => {
      maxAbs = Math.max(maxAbs, Math.abs(probe() - before))
    }, "After the operation")
    const final = probe() - before
    hooks.after?.()
    return { final, maxAbs }
  }

  // ---------------------------------------------------------------------------
  // Traces (`?trace=1`)

  /** What a trace records at one point of a repetition. */
  const traceState = (anchorKey: ItemKey, rowKey: ItemKey): TraceState => {
    const box = container()
    const row = rectOf(rowKey)
    const media = rowElement(rowKey)?.querySelector("[data-lab-media]")
    const debug = controller.debug()
    return {
      reference: debug.anchors.find((anchor) => rowElement(anchor.key))?.key ?? null,
      anchorTop: topOf(anchorKey) ?? null,
      rowTop: row?.top ?? null,
      rowHeight: row ? row.bottom - row.top : null,
      boxHeight: media ? media.getBoundingClientRect().height : null,
      scrollTop: box.scrollTop,
      scrollHeight: box.scrollHeight,
      offsets: { ...debug.offsets },
    }
  }

  /** One repetition's trace: the states at the points named, plus the measured drift. */
  const traceRep = (anchorKey: ItemKey, rowKey: ItemKey, extra: Record<string, unknown> = {}) => {
    const entry: TraceEntry = { anchorKey, rowKey, ...extra, states: {}, drift: null, sameAnchor: null }
    const mark = (point: string) => {
      if (lab.tracing) entry.states[point] = traceState(anchorKey, rowKey)
    }
    const finish = (measured: RepMeasure) => {
      entry.drift = measured
      const before = entry.states["before"]?.reference
      const after = entry.states["after"]?.reference
      entry.sameAnchor = before === undefined || after === undefined ? null : before === after
      return measured
    }
    return { entry, mark, finish }
  }

  const randomFor = (name: string): Random => {
    let hash = lab.seed >>> 0
    for (let i = 0; i < name.length; i++) hash = Math.imul(hash ^ name.charCodeAt(i), 16777619) >>> 0
    return createRandom(hash)
  }

  const mode = (): TimelineMode => controller.mode.peek()

  /** Fresh window at latest, following, nothing pending. */
  const reopen = async (rows?: number) => {
    core.openLatest(rows)
    await waiter.frames(2, undefined, "Opening at latest")
    await settle("Opening at latest settles")
  }

  const toFollowing = async () => {
    await reopen()
    if (mode() !== "following") throw new Error(`Expected to follow latest after opening, mode is ${mode()}.`)
  }

  /**
   * Fresh window, then the user scrolls `viewports` up and lets go. `rows`
   * loaded rows: few enough for all of them to render (the controller's first
   * range is `viewport / 24 + 30` rows), so pages prepended to the window
   * render at once, as they do when a reader reaches the top.
   */
  const toReading = async (viewports = 2.5, rows?: number) => {
    await reopen(rows)
    await userScrollBy(-viewportHeight() * viewports)
    await settle("Scrolling settles")
    if (mode() !== "reading") throw new Error(`Expected reading after scrolling up, mode is ${mode()}.`)
  }

  /** Message rows entirely above the viewport. */
  const keysAbove = () => messageKeys().filter((key) => (rectOf(key)?.bottom ?? 0) < -1)

  const pickAbove = (random: Random) => {
    const above = keysAbove()
    if (above.length === 0) throw new Error("No rendered row above the viewport.")
    // The nearest 40 rows: what a real media load above the reader looks like.
    return random.pick(above.slice(-40))
  }

  const rowIdOf = (key: ItemKey) => {
    const rowId = core.rowIdOfKey(key)
    if (!rowId) throw new Error(`${key} is not a message row.`)
    return rowId
  }

  const streamWords = (random: Random, count: number) =>
    Array.from({ length: count }, () => random.pick(STREAM_WORDS)).join(" ")

  const newKeys = (before: readonly ItemKey[]) => {
    const seen = new Set(before)
    return surface.keys.peek().filter((key) => !seen.has(key)).length
  }

  /** Items whose object changed between two renders of the same keys (a group edge, a separator's date). */
  const changedItems = (before: Map<ItemKey, unknown>) => {
    let changed = 0
    for (const item of controller.rendered.peek()) {
      const previous = before.get(item.key)
      if (previous !== undefined && previous !== item) changed += 1
    }
    return changed
  }

  const renderedItems = () => new Map(controller.rendered.peek().map((item) => [item.key, item] as const))

  // ---------------------------------------------------------------------------
  // Running and recording

  let queue: Promise<unknown> = Promise.resolve()
  /** Operations run one at a time, whoever calls them. */
  const serial = <T>(fn: () => Promise<T>): Promise<T> => {
    const next = queue.then(fn, fn)
    queue = next.catch(() => undefined)
    return next
  }

  const run = async (operation: string, setup: () => Promise<void>, body: Body): Promise<OpResult> => {
    const started = performance.now()
    let modeBefore = mode()
    lab.setStatus({ state: "running", message: operation })
    try {
      await setup()
      modeBefore = mode()
      counter.reset()
      const outcome = await body()
      const result = summarize({
        operation,
        ...outcome,
        renders: renders(),
        modeBefore,
        modeAfter: mode(),
        ms: performance.now() - started,
      })
      lab.record(result)
      return result
    } catch (error) {
      const result = failedResult(operation, error, modeBefore, performance.now() - started)
      lab.record(result)
      // Without frames nothing after this can be measured either: stop the run.
      if (error instanceof FrameTimeoutError) throw error
      return result
    }
  }

  // ---------------------------------------------------------------------------
  // Operations

  const appendFollowing = (reps = REPETITIONS.append) =>
    run("append one (following)", toFollowing, async () => {
      const measures: RepMeasure[] = []
      let added = 0
      for (let i = 0; i < reps; i++) {
        const before = surface.keys.peek()
        measures.push(await measure(bottomGap, () => core.append()))
        added += newKeys(before)
      }
      const r = renders()
      return {
        metric: "bottom",
        reps: measures,
        checks: [
          { ok: mode() === "following", message: `mode ${mode()} after appending while following` },
          { ok: r.rows === added, message: `${r.rows} row renders for ${added} new rows` },
        ],
        notes: [`${added} new rows`],
      }
    })

  const appendReading = (reps = REPETITIONS.append) =>
    run("append while reading above", toReading, async () => {
      const measures: RepMeasure[] = []
      let added = 0
      for (let i = 0; i < reps; i++) {
        const before = surface.keys.peek()
        const { probe } = anchorProbe()
        measures.push(await measure(probe, () => core.append()))
        added += newKeys(before)
      }
      const button = controller.latestButton.peek()
      const r = renders()
      return {
        metric: "anchor",
        reps: measures,
        checks: [
          { ok: mode() === "reading", message: `mode ${mode()} after rows arrived below a reader` },
          { ok: button.visible, message: "jump to latest is not shown while reading" },
          { ok: button.count === reps, message: `jump to latest counts ${button.count}, expected ${reps}` },
          { ok: r.rows === added, message: `${r.rows} row renders for ${added} new rows` },
        ],
        notes: [`jump to latest shows ${button.count}`],
      }
    })

  const resizeAbove = (reps = REPETITIONS.resize) =>
    run("resize a row above the viewport", toReading, async () => {
      const random = randomFor("resize")
      const measures: RepMeasure[] = []
      const trace: TraceEntry[] = []
      for (let i = 0; i < reps; i++) {
        const key = pickAbove(random)
        const rowId = rowIdOf(key)
        const current = core.extras(rowId).peek().extra
        const amount = random.int(1, 60) + random.pick([0, 0.25, 0.5, 0.75, 0.333])
        const next = current > 90 ? Math.max(0, current - amount) : current + amount
        const { key: anchorKey, probe } = anchorProbe()
        const t = traceRep(anchorKey, key, { extraBefore: current, extraAfter: next })
        measures.push(
          t.finish(
            await measure(probe, () => core.updateExtras(rowId, (e) => ({ ...e, extra: next })), 2, {
              before: () => t.mark("before"),
              after: () => t.mark("after"),
            }),
          ),
        )
        trace.push(t.entry)
      }
      if (lab.tracing) lab.setTrace("resizeAbove", trace)
      const r = renders()
      return {
        metric: "anchor",
        reps: measures,
        checks: [{ ok: r.list === 0 && r.rows === 0, message: `a row's own change rendered ${r.list} lists and ${r.rows} row wrappers` }],
      }
    })

  const lateMedia = (reps = REPETITIONS.lateMedia) =>
    run("late media above the viewport", toReading, async () => {
      const random = randomFor("media")
      const measures: RepMeasure[] = []
      const trace: TraceEntry[] = []
      let generated = 0
      let armedChangedLayout = 0
      for (let i = 0; i < reps; i++) {
        // Prefer generated late media that has not arrived. Otherwise arm a row that has no media box at all:
        // an empty box changes no layout. (Arming a row that already showed media would shrink it, a layout
        // change of its own that the measurement must not hide.)
        const above = keysAbove()
        let key = [...above].reverse().find((k) => {
          const media = core.extras(rowIdOf(k)).peek().media
          return media !== null && media.late && media.height === 0
        })
        const armed = key === undefined
        if (key) generated += 1
        else {
          const candidates = above.slice(-40).filter((k) => core.extras(rowIdOf(k)).peek().media === null)
          if (candidates.length === 0) throw new Error("No row without media above the viewport to arm.")
          key = random.pick(candidates)
        }
        const rowKey = key
        const rowId = rowIdOf(rowKey)
        const finalHeight = random.int(80, 260) + random.pick([0, 0.5, 0.25])
        const { key: anchorKey, probe } = anchorProbe()
        const t = traceRep(anchorKey, rowKey, { armed })
        // "Before" is read before arming, so anything arming did to the layout is in the drift.
        const measured = await measure(
          probe,
          async () => {
            if (armed) {
              const height = () => {
                const rect = rectOf(rowKey)
                return rect ? rect.bottom - rect.top : Number.NaN
              }
              const heightBefore = height()
              core.updateExtras(rowId, (e) => ({ ...e, media: { height: 0, finalHeight, late: true } }))
              await waiter.frames(2, undefined, "Arming a late media box")
              t.mark("armed")
              if (!(Math.abs(height() - heightBefore) <= 0.01)) armedChangedLayout += 1
            }
            core.updateExtras(rowId, (e) => (e.media ? { ...e, media: { ...e.media, height: e.media.finalHeight } } : e))
          },
          2,
          { before: () => t.mark("before"), after: () => t.mark("after") },
        )
        measures.push(t.finish(measured))
        trace.push(t.entry)
      }
      if (lab.tracing) lab.setTrace("lateMedia", trace)
      return {
        metric: "anchor",
        reps: measures,
        checks: [{ ok: armedChangedLayout === 0, message: `arming an empty box changed ${armedChangedLayout} rows' height` }],
        notes: [`${generated} generated late boxes, ${reps - generated} armed by the lab`],
      }
    })

  /** Grow `key`'s text every frame for `frames` frames, sampling `probe` at the start of each. */
  const streamInto = async (key: ItemKey, probe: () => number, frames: number, random: Random): Promise<RepMeasure> => {
    const rowId = rowIdOf(key)
    await waiter.nextFrame("Before streaming")
    const before = probe()
    let maxAbs = 0
    for (let i = 0; i < frames + 2; i++) {
      if (i < frames) core.updateExtras(rowId, (e) => ({ ...e, stream: `${e.stream} ${streamWords(random, 3)}` }))
      await waiter.nextFrame("Streaming")
      maxAbs = Math.max(maxAbs, Math.abs(probe() - before))
    }
    return { final: probe() - before, maxAbs }
  }

  const streamChecks = (): Check[] => {
    const r = renders()
    return [{ ok: r.list === 0 && r.rows === 0, message: `streaming rendered ${r.list} lists and ${r.rows} row wrappers` }]
  }

  const streamAbove = (frames = REPETITIONS.streamFrames) =>
    run("stream a row above the reader", toReading, async () => {
      const random = randomFor("stream-above")
      const key = pickAbove(random)
      const { probe } = anchorProbe()
      return { metric: "anchor", reps: [await streamInto(key, probe, frames, random)], checks: streamChecks(), notes: [`${frames} frames`] }
    })

  const streamBelow = (frames = REPETITIONS.streamFrames) =>
    run("stream a row below the reader's anchor", toReading, async () => {
      const random = randomFor("stream-below")
      const { key: anchor, probe } = anchorProbe()
      const anchorTop = probe()
      const height = viewportHeight()
      const key = messageKeys().find((k) => {
        const rect = rectOf(k)
        return k !== anchor && rect !== undefined && rect.top > anchorTop + 40 && rect.top < height * 0.7
      })
      if (!key) throw new Error("No visible row below the anchor to stream into.")
      return { metric: "anchor", reps: [await streamInto(key, probe, frames, random)], checks: streamChecks(), notes: [`${frames} frames`] }
    })

  const streamBottom = (frames = REPETITIONS.streamFrames) =>
    run("stream at the bottom (following)", toFollowing, async () => {
      const random = randomFor("stream-bottom")
      const key = core.append("Streaming:")
      await waiter.frames(2, undefined, "A streaming message arrives")
      counter.reset()
      const measured = await streamInto(key, bottomGap, frames, random)
      return {
        metric: "bottom",
        reps: [measured],
        checks: [...streamChecks(), { ok: mode() === "following", message: `mode ${mode()} after streaming at the bottom` }],
        notes: [`${frames} frames`],
      }
    })

  const resizeFrame = (name: string, setup: () => Promise<void>, metric: "anchor" | "bottom", sizes: { width?: number; height?: number }[]) =>
    run(name, setup, async () => {
      const measures: RepMeasure[] = []
      for (const size of sizes) {
        const probe = metric === "bottom" ? bottomGap : anchorProbe().probe
        measures.push(await measure(probe, () => lab.setFrameSize(size), 3))
      }
      return {
        metric,
        reps: measures,
        checks: metric === "bottom" ? [{ ok: mode() === "following", message: `mode ${mode()} after resizing while following` }] : [],
        notes: [sizes.map((s) => `${s.width ?? "·"}×${s.height ?? "·"}`).join(", ")],
      }
    })

  const widthReading = () =>
    resizeFrame("container width (reading)", toReading, "anchor", [{ width: 400 }, { width: 760 }, { width: 480 }, { width: DEFAULT_FRAME.width }])
  const heightReading = () =>
    resizeFrame("container height (reading)", toReading, "anchor", [{ height: 420 }, { height: 720 }, { height: DEFAULT_FRAME.height }])
  const heightFollowing = () =>
    resizeFrame("container height (following)", toFollowing, "bottom", [{ height: 420 }, { height: 720 }, { height: DEFAULT_FRAME.height }])

  const insets = (name: string, setup: () => Promise<void>, metric: "anchor" | "bottom") =>
    run(name, setup, async () => {
      const measures: RepMeasure[] = []
      for (const inset of [96, 140, 0]) {
        const probe = metric === "bottom" ? bottomGap : anchorProbe().probe
        measures.push(await measure(probe, () => lab.setComposerInset(inset), 3))
      }
      return { metric, reps: measures, notes: ["composer inset 96, 140, 0"] }
    })

  const insetReading = () => insets("composer inset (reading)", toReading, "anchor")
  const insetFollowing = () => insets("composer inset (following)", toFollowing, "bottom")

  const prepend = (reps = REPETITIONS.prepend) =>
    run("prepend a page", () => toReading(1.5, HEAD_ROWS), async () => {
      const random = randomFor("prepend")
      const measures: RepMeasure[] = []
      let added = 0
      let changed = 0
      const everRendered = new Set(surface.keys.peek())
      let reentered = 0
      for (let i = 0; i < reps; i++) {
        const count = random.int(10, 40)
        const box = container()
        // Renders are accounted over the whole repetition: the prepend, the reader scrolling, any trim.
        const keysBefore = surface.keys.peek()
        const itemsBefore = renderedItems()
        const { probe } = anchorProbe()
        let offsetBefore = 0
        measures.push(
          await measure(probe, () => {
            offsetBefore = box.scrollTop
            if (core.prepend(count) === 0) throw new Error("The lab's history has no older rows left.")
          }),
        )
        // The reader keeps scrolling up, back to the same distance from the head for the next page: by the
        // controller's correction for the rows inserted above (not by the content's growth, which a trim of
        // rows below in the same frames would understate, sending the reader down into a widening of the range).
        await userScrollBy(-(box.scrollTop - offsetBefore))
        // Let scrolling go idle now and then, so the controller trims as it would for a real reader.
        if (i % 5 === 4) await settle("Scrolling settles between pages")
        const seen = new Set(keysBefore)
        for (const key of surface.keys.peek()) {
          if (seen.has(key)) continue
          added += 1
          if (everRendered.has(key)) reentered += 1
          everRendered.add(key)
        }
        changed += changedItems(itemsBefore)
      }
      const r = renders()
      return {
        metric: "anchor",
        reps: measures,
        checks: [
          { ok: mode() === "reading", message: `mode ${mode()} after prepending` },
          {
            ok: r.rows === added + changed,
            message: `${r.rows} row renders for ${added} rows mounted and ${changed} changed items`,
          },
        ],
        notes: [
          `${added} rows mounted (${reentered} of them had been rendered before), ${changed} existing items changed (group edges, day separators)`,
        ],
      }
    })

  const trim = () =>
    run("trim", () => toReading(1.5, HEAD_ROWS), async () => {
      const measures: RepMeasure[] = []
      let trimmedAt = -1
      let before = 0
      let after = 0
      for (let i = 0; i < 20 && trimmedAt < 0; i++) {
        before = controller.rendered.peek().length
        const { probe } = anchorProbe()
        measures.push(await measure(probe, () => core.prepend(40)))
        after = controller.rendered.peek().length
        if (after < before) trimmedAt = i
      }
      const visible = messageKeys().filter((key) => {
        const rect = rectOf(key)
        return rect !== undefined && rect.bottom > 0 && rect.top < viewportHeight()
      }).length
      return {
        metric: "anchor",
        reps: measures,
        checks: [
          { ok: trimmedAt >= 0, message: "the controller never trimmed" },
          { ok: after <= TRIM_TO_ROWS + visible + 2, message: `${after} rows rendered after trimming` },
        ],
        notes: [`pages of 40 until the trim; rendered ${before} → ${after} rows at page ${trimmedAt + 1}`],
      }
    })

  /** Wait for a jump to land, serving any window request it makes after `serveAfterMs`. */
  const land = async (what: string, serveAfterMs = 150) => {
    let served = false
    const started = performance.now()
    await waiter.until(() => {
      if (!served && performance.now() - started >= serveAfterMs) {
        served = core.servePending((request) => typeof request === "object" || request === "latest") !== undefined
      }
      return mode() !== "target" && settled()
    }, what)
  }

  const landingError = (key: ItemKey) => {
    const box = container()
    const rect = rectOf(key)
    if (!rect) throw new Error(`The target ${key} is not rendered after landing.`)
    const insets = surface.insets()
    const expected = centeredOffset({
      offset: box.scrollTop,
      rowTop: rect.top,
      rowBottom: rect.bottom,
      viewportHeight: box.clientHeight,
      contentHeight: box.scrollHeight,
      insetTop: insets.top,
      insetBottom: insets.bottom,
    })
    return expected - box.scrollTop
  }

  const jump = (name: string, pick: () => ItemKey | { id: MessageID }) =>
    run(name, toReading, async () => {
      const target = pick()
      const id = typeof target === "string" ? core.messageOfKey(target)?.row.messageId : target.id
      if (id === undefined) throw new Error("The jump target has no message ID.")
      const seq = controller.highlight.peek()?.seq ?? 0
      const key = typeof target === "string" ? target : `m:${core.history[Number(id) - 1]!.row.id}`
      // Watch the DOM for the flash from before the jump: in a throttled window frames can be further
      // apart than the flash lasts (850 ms), so looking a frame or two after landing can miss it.
      let flashing = false
      const observer = new MutationObserver((records) => {
        for (const record of records)
          for (const node of record.addedNodes) {
            if (!(node instanceof HTMLElement)) continue
            // The flash added to a mounted row, or a row mounted already flashing.
            const flashes = node.hasAttribute("data-timeline-flash") ? [node] : Array.from(node.querySelectorAll("[data-timeline-flash]"))
            if (flashes.some((flash) => flash.parentElement?.getAttribute("data-timeline-key") === key)) flashing = true
          }
      })
      observer.observe(container(), { childList: true, subtree: true })
      controller.jumpToMessage(id)
      try {
        await land(`Landing on message ${id}`)
        await waiter.nextFrame("The flash renders")
      } finally {
        observer.disconnect()
      }
      const error = landingError(key)
      const highlight = controller.highlight.peek()
      return {
        metric: "landing",
        reps: [{ final: error, maxAbs: Math.abs(error) }],
        checks: [
          { ok: highlight?.key === key && highlight.seq > seq, message: "the target was not highlighted" },
          { ok: flashing, message: "the view did not flash the target row" },
          { ok: mode() === "reading" || mode() === "following", message: `mode ${mode()} after landing` },
        ],
        notes: [`message ${id}`],
      }
    })

  const jumpNear = () =>
    jump("jump to a near message", () => {
      const height = viewportHeight()
      const key = messageKeys().find((k) => {
        const rect = rectOf(k)
        return rect !== undefined && rect.top > height * 1.3 && rect.top < height * 1.9
      })
      if (!key) throw new Error("No rendered message about a viewport below.")
      return key
    })

  const jumpFar = () =>
    jump("jump to a far message (loaded)", () => {
      const { lo } = core.bounds()
      return `m:${core.history[lo + 3]!.row.id}`
    })

  const jumpUnloaded = () =>
    jump("jump to an uncached message", () => {
      const { lo } = core.bounds()
      return { id: messageId(Math.max(1, lo - 500)) }
    })

  const jumpLatest = () =>
    run("jump to latest", toReading, async () => {
      controller.jumpToLatest()
      await land("Landing at latest")
      const gap = bottomGap()
      return {
        metric: "landing",
        reps: [{ final: gap, maxAbs: gap }],
        checks: [{ ok: mode() === "following", message: `mode ${mode()} after jumping to latest` }],
      }
    })

  const keyboard = () =>
    run("keyboard focus and paging", toFollowing, async () => {
      const box = container()
      const focused = surface.focus()
      const active = box.ownerDocument.activeElement === box
      box.dispatchEvent(new KeyboardEvent("keydown", { key: "PageUp", bubbles: true, cancelable: true }))
      const detached = mode() === "reading"
      await settle("Key input settles")
      return {
        metric: "none",
        reps: [],
        checks: [
          { ok: focused && active, message: "focus() did not put focus on the list" },
          { ok: detached, message: "Page Up on the focused list did not count as upward user input" },
          { ok: mode() === "following", message: `mode ${mode()} after a key that scrolled nothing` },
        ],
        notes: ["synthetic keys do not scroll; real paging is the browser's own on the focused list"],
      }
    })

  const UNREAD_BEHIND = 300
  const lineError = () => {
    const top = topOf("unread")
    if (top === undefined) throw new Error("The unread line is not rendered.")
    return top - surface.insets().top
  }

  const openUnreadCached = () =>
    run("open at unread (cached)", reopen, async () => {
      core.openUnread(UNREAD_BEHIND, true)
      let hiddenSeen = controller.hidden.peek()
      let maxAbs = 0
      let final = 0
      await waiter.frames(4, () => {
        hiddenSeen ||= controller.hidden.peek()
        final = lineError()
        maxAbs = Math.max(maxAbs, Math.abs(final))
      }, "Opening at unread")
      return {
        metric: "line",
        reps: [{ final, maxAbs }],
        checks: [
          { ok: !hiddenSeen, message: "a cached open hid the list" },
          { ok: mode() === "restoring", message: `mode ${mode()} after opening at the unread line` },
        ],
        notes: [`read marker ${UNREAD_BEHIND} messages back; line sampled from the first frame`],
      }
    })

  const openUnreadUncached = (delayMs = 400) =>
    run("open at unread (not cached)", reopen, async () => {
      core.openUnread(UNREAD_BEHIND, false)
      const hiddenAtOpen = controller.hidden.peek()
      let busy = false
      let spinnerSeen = false
      let shownEarly = false
      const started = performance.now()
      await waiter.until(() => performance.now() - started >= delayMs, "Waiting for the delayed rows", {
        each: () => {
          spinnerSeen ||= controller.spinner.peek()
          shownEarly ||= !controller.hidden.peek()
          busy ||= container().getAttribute("aria-busy") === "true"
        },
      })
      if (!core.servePending((request) => typeof request === "object")) throw new Error("The controller did not ask for rows around the unread line.")
      let maxAbs = 0
      let final = 0
      let framesHidden = 0
      await waiter.until(() => !controller.hidden.peek(), "The list is revealed", {
        each: () => {
          if (controller.hidden.peek()) framesHidden += 1
          else {
            final = lineError()
            maxAbs = Math.max(maxAbs, Math.abs(final))
          }
        },
      })
      await waiter.frames(3, () => {
        final = lineError()
        maxAbs = Math.max(maxAbs, Math.abs(final))
      }, "After the reveal")
      return {
        metric: "line",
        reps: [{ final, maxAbs }],
        checks: [
          { ok: hiddenAtOpen && busy, message: "the list was not hidden while the rows were loading" },
          { ok: !shownEarly, message: "the list showed before the unread rows arrived" },
          { ok: spinnerSeen, message: `no spinner during a ${delayMs} ms load` },
          { ok: mode() === "restoring", message: `mode ${mode()} after the reveal` },
        ],
        notes: [`rows delayed ${delayMs} ms; spinner ${spinnerSeen ? "shown" : "not shown"}; ${framesHidden} frames hidden after the rows arrived`],
      }
    })

  // ---------------------------------------------------------------------------
  // Streaming by hand

  let streaming: { stop: boolean } | null = null

  const startStream = (where: "above" | "below" | "bottom") => {
    if (streaming) streaming.stop = true
    const session = { stop: false }
    streaming = session
    const random = randomFor(`manual-${where}`)
    let key: ItemKey | undefined
    if (where === "bottom") key = core.append("Streaming:")
    else if (where === "above") key = keysAbove().at(-1)
    else key = messageKeys().find((k) => (rectOf(k)?.top ?? -1) > viewportHeight() * 0.4)
    if (!key) return
    const rowId = rowIdOf(key)
    void (async () => {
      while (!session.stop) {
        core.updateExtras(rowId, (e) => ({ ...e, stream: `${e.stream} ${streamWords(random, 3)}` }))
        try {
          await waiter.nextFrame("Streaming")
        } catch {
          return
        }
      }
    })()
  }

  const stopStream = () => {
    if (streaming) streaming.stop = true
    streaming = null
  }

  // ---------------------------------------------------------------------------
  // Run all

  const sequence: [string, () => Promise<OpResult>][] = [
    ["appendFollowing", () => appendFollowing()],
    ["streamBottom", () => streamBottom()],
    ["heightFollowing", heightFollowing],
    ["insetFollowing", insetFollowing],
    ["keyboard", keyboard],
    ["appendReading", () => appendReading()],
    ["resizeAbove", () => resizeAbove()],
    ["lateMedia", () => lateMedia()],
    ["streamAbove", () => streamAbove()],
    ["streamBelow", () => streamBelow()],
    ["widthReading", widthReading],
    ["heightReading", heightReading],
    ["insetReading", insetReading],
    ["prepend", () => prepend()],
    ["trim", trim],
    ["jumpNear", jumpNear],
    ["jumpFar", jumpFar],
    ["jumpUnloaded", jumpUnloaded],
    ["jumpLatest", jumpLatest],
    ["openUnreadCached", openUnreadCached],
    ["openUnreadUncached", () => openUnreadUncached()],
  ]

  /** Lab state every measured run starts from. Requests are served by the operations, not on a timer. */
  const prepare = () => {
    stopStream()
    core.setAutoServe(false)
    lab.setComposerInset(0)
    lab.setFrameSize({ ...DEFAULT_FRAME })
  }

  const finish = async () => {
    core.setAutoServe(true)
    lab.setComposerInset(0)
    lab.setFrameSize({ ...DEFAULT_FRAME })
    core.openLatest()
    await waiter.frames(1, undefined, "Reopening at latest").catch(() => undefined)
  }

  /** One operation by itself (a button, or the control API). */
  const single = (fn: () => Promise<OpResult>) =>
    serial(async () => {
      prepare()
      try {
        const result = await fn()
        lab.setStatus({ state: "done", message: `${result.operation}: ${result.pass ? "pass" : "FAIL"}` })
        return result
      } catch (error) {
        lab.setStatus({ state: "error", message: error instanceof Error ? error.message : String(error) })
        throw error
      } finally {
        core.setAutoServe(true)
      }
    })

  const runAll = () =>
    serial(async () => {
      lab.beginRun()
      prepare()
      core.resetExtras()
      try {
        for (const [, fn] of sequence) await fn()
        const results = lab.results.peek()
        const failed = results.filter((result) => !result.pass).length
        lab.setStatus({ state: "done", message: `${results.length - failed} passed, ${failed} failed` })
      } catch (error) {
        lab.setStatus({ state: "error", message: error instanceof Error ? error.message : String(error) })
      } finally {
        await finish()
      }
      return lab.snapshot()
    })

  const operations = {
    appendFollowing: (reps?: number) => single(() => appendFollowing(reps)),
    appendReading: (reps?: number) => single(() => appendReading(reps)),
    prepend: (reps?: number) => single(() => prepend(reps)),
    resizeAbove: (reps?: number) => single(() => resizeAbove(reps)),
    lateMedia: (reps?: number) => single(() => lateMedia(reps)),
    streamAbove: (frames?: number) => single(() => streamAbove(frames)),
    streamBelow: (frames?: number) => single(() => streamBelow(frames)),
    streamBottom: (frames?: number) => single(() => streamBottom(frames)),
    widthReading: () => single(widthReading),
    heightReading: () => single(heightReading),
    heightFollowing: () => single(heightFollowing),
    insetReading: () => single(insetReading),
    insetFollowing: () => single(insetFollowing),
    jumpNear: () => single(jumpNear),
    jumpFar: () => single(jumpFar),
    jumpUnloaded: () => single(jumpUnloaded),
    jumpLatest: () => single(jumpLatest),
    keyboard: () => single(keyboard),
    openUnreadCached: () => single(openUnreadCached),
    openUnreadUncached: (delayMs?: number) => single(() => openUnreadUncached(delayMs)),
    trim: () => single(trim),
    runAll,
    /** Back to a window at latest with requests served on a timer (for scrolling by hand). */
    reset: () => serial(finish),
    startStream,
    stopStream,
    results: () => lab.snapshot(),
  }
  return operations
}

export type TimelineLabControl = ReturnType<typeof createOperations>
