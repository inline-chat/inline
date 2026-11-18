/**
 * Timeline lab: `TimelineView` over the real timeline controller and DOM
 * host, on a seeded history with variable row heights, late media and
 * streaming rows. Every operation measures the anchored row's drift in the
 * browser; "Run all" runs them in sequence and writes the table here and to
 * `globalThis.__timelineLab`. `globalThis.__timelineLabControl` drives it
 * from a script. See web/src/features/timeline/README.md ("The lab").
 *
 * Query parameters: `seed`, `theme=light|dark`, `dir=rtl`, `run=all`, and
 * `trace=1` for per-repetition traces of the resize and late media runs on
 * `__timelineLab.trace`.
 */

import { useElement, useSignal } from "@inline/reactive/react"
import { countRender, createRenderCounter } from "@inline/reactive/react/testing"
import type { DaySeparatorItem, MessageItem, TimelineItem } from "@inline/timeline"
import { Button } from "@inline/ui/react"
import { color } from "@inline/ui/tokens/color.stylex"
import { font } from "@inline/ui/tokens/font.stylex"
import { radius } from "@inline/ui/tokens/radius.stylex"
import { space } from "@inline/ui/tokens/space.stylex"
import * as stylex from "@stylexjs/stylex"
import { memo, useState, type ReactNode } from "react"
import { createRoot } from "react-dom/client"
import { TimelineView } from "../../features/timeline"
import { createTimelineLab, DEFAULT_SEED, type TimelineLab } from "./lab"
import { createOperations, REPETITIONS, type TimelineLabControl } from "./operations"
import { DRIFT_BUDGET_PX, resultsAsText } from "./results"

if (import.meta.env.DEV) {
  void import("virtual:stylex:runtime")
}

type Theme = "system" | "light" | "dark"
type Dir = "ltr" | "rtl"

const params = new URLSearchParams(location.search)
const seed = Number(params.get("seed")) || DEFAULT_SEED
const applyTheme = (theme: Theme) => {
  document.documentElement.style.colorScheme = theme === "system" ? "light dark" : theme
}
const applyDir = (dir: Dir) => {
  document.documentElement.dir = dir
}
const initialTheme: Theme = params.get("theme") === "dark" ? "dark" : params.get("theme") === "light" ? "light" : "system"
const initialDir: Dir = params.get("dir") === "rtl" ? "rtl" : "ltr"
applyTheme(initialTheme)
applyDir(initialDir)

// No StrictMode: render counts are part of what the lab measures, and StrictMode renders twice.
const counter = createRenderCounter()
const lab = createTimelineLab({ seed, counter, trace: params.get("trace") === "1" })
const control = createOperations(lab)
;(globalThis as { __timelineLabControl?: TimelineLabControl }).__timelineLabControl = control

// ---------------------------------------------------------------------------
// Rows (plain lab rows; the app's message rows are a separate feature)

const SENDERS: Record<string, string> = { "1": "You", "2": "Ada", "3": "Grace", "4": "Linus" }
const timeFormat = new Intl.DateTimeFormat("en", { hour: "2-digit", minute: "2-digit", timeZone: "UTC" })
const dayFormat = new Intl.DateTimeFormat("en", { weekday: "long", month: "long", day: "numeric", timeZone: "UTC" })

const LabMessage = memo(function LabMessage(props: { item: MessageItem }) {
  countRender("lab:row")
  const { row } = props.item
  const extras = useSignal(lab.core.extras(row.id))
  return (
    <div {...stylex.props(rowStyles.message, props.item.firstInGroup && rowStyles.groupStart)}>
      {props.item.firstInGroup ? (
        <div {...stylex.props(rowStyles.sender)}>
          <span {...stylex.props(row.out ? rowStyles.nameOut : rowStyles.name)}>{SENDERS[row.fromId] ?? row.fromId}</span>
          <span {...stylex.props(rowStyles.time)}>{timeFormat.format(row.date * 1000)}</span>
          <span {...stylex.props(rowStyles.time)}>#{row.messageId}</span>
        </div>
      ) : null}
      <p dir="auto" {...stylex.props(rowStyles.text)}>
        {row.text}
        {extras.stream ? <span {...stylex.props(rowStyles.stream)}>{extras.stream}</span> : null}
      </p>
      {extras.media ? (
        <div
          aria-label={extras.media.height > 0 ? "Media" : "Media loading"}
          data-lab-media=""
          {...stylex.props(rowStyles.media, extras.media.height > 0 && rowStyles.mediaShown, dynamic.blockSize(extras.media.height))}
        />
      ) : null}
      {extras.extra > 0 ? <div {...stylex.props(rowStyles.extra, dynamic.blockSize(extras.extra))} /> : null}
    </div>
  )
})

function DayRow(props: { item: DaySeparatorItem }) {
  return (
    <div {...stylex.props(rowStyles.day)}>
      <span {...stylex.props(rowStyles.dayLabel)}>{dayFormat.format(props.item.date * 1000)}</span>
    </div>
  )
}

function UnreadRow() {
  return (
    <div role="separator" aria-label="Unread messages" {...stylex.props(rowStyles.unread)}>
      <span {...stylex.props(rowStyles.unreadRule)} />
      <span {...stylex.props(rowStyles.unreadLabel)}>Unread messages</span>
      <span {...stylex.props(rowStyles.unreadRule)} />
    </div>
  )
}

/** Module level, so it is stable: changing it would render every row. */
const renderItem = (item: TimelineItem) => {
  if (item.kind === "message") return <LabMessage item={item} />
  if (item.kind === "day") return <DayRow item={item} />
  return <UnreadRow />
}

// ---------------------------------------------------------------------------
// Page

function Frame(props: { lab: TimelineLab }) {
  const ref = useElement(props.lab.frame)
  const inset = useSignal(props.lab.composerInset)
  return (
    <div ref={ref} {...stylex.props(pageStyles.frame)}>
      <TimelineView surface={props.lab.surface} renderItem={renderItem} label="Lab messages" />
      {inset > 0 ? <div aria-hidden="true" {...stylex.props(pageStyles.composer, dynamic.blockSize(inset))} /> : null}
    </div>
  )
}

function Group(props: { title: string; children: ReactNode }) {
  return (
    <fieldset {...stylex.props(pageStyles.group)}>
      <legend {...stylex.props(pageStyles.legend)}>{props.title}</legend>
      <div {...stylex.props(pageStyles.buttons)}>{props.children}</div>
    </fieldset>
  )
}

function Act(props: { label: string; run: () => unknown }) {
  return (
    <Button size="small" onClick={() => void props.run()}>
      {props.label}
    </Button>
  )
}

function Controls() {
  const c = control
  return (
    <div {...stylex.props(pageStyles.controls)}>
      <Group title="Measure everything">
        <Button size="small" variant="primary" onClick={() => void c.runAll()}>
          Run all
        </Button>
        <Act label="Reset" run={c.reset} />
      </Group>
      <Group title="Following latest">
        <Act label="Append one" run={() => c.appendFollowing(1)} />
        <Act label="Stream at bottom" run={() => c.streamBottom()} />
        <Act label="Change height" run={c.heightFollowing} />
        <Act label="Composer inset" run={c.insetFollowing} />
        <Act label="Keyboard focus" run={c.keyboard} />
      </Group>
      <Group title="Reading above">
        <Act label="Append while reading" run={() => c.appendReading(1)} />
        <Act label="Resize a row above" run={() => c.resizeAbove(1)} />
        <Act label={`Resize ×${REPETITIONS.resize}`} run={() => c.resizeAbove()} />
        <Act label="Resolve late media" run={() => c.lateMedia(1)} />
        <Act label="Stream above" run={() => c.streamAbove()} />
        <Act label="Stream below anchor" run={() => c.streamBelow()} />
        <Act label="Change width" run={c.widthReading} />
        <Act label="Change height" run={c.heightReading} />
        <Act label="Composer inset" run={c.insetReading} />
      </Group>
      <Group title="History">
        <Act label="Prepend a page" run={() => c.prepend(1)} />
        <Act label={`Prepend ×${REPETITIONS.prepend}`} run={() => c.prepend()} />
        <Act label="Trim" run={c.trim} />
      </Group>
      <Group title="Navigation and opening">
        <Act label="Jump near" run={c.jumpNear} />
        <Act label="Jump far" run={c.jumpFar} />
        <Act label="Jump uncached" run={c.jumpUnloaded} />
        <Act label="Jump to latest" run={c.jumpLatest} />
        <Act label="Unread, cached" run={c.openUnreadCached} />
        <Act label="Unread, not cached" run={() => c.openUnreadUncached()} />
      </Group>
      <Group title="By hand (not measured)">
        <Act label="Stream above" run={() => c.startStream("above")} />
        <Act label="Stream below" run={() => c.startStream("below")} />
        <Act label="Stream at bottom" run={() => c.startStream("bottom")} />
        <Act label="Stop stream" run={c.stopStream} />
        <Act label="Width 400" run={() => lab.setFrameSize({ width: 400 })} />
        <Act label="Width 560" run={() => lab.setFrameSize({ width: 560 })} />
        <Act label="Width 760" run={() => lab.setFrameSize({ width: 760 })} />
        <Act label="Height 420" run={() => lab.setFrameSize({ height: 420 })} />
        <Act label="Height 600" run={() => lab.setFrameSize({ height: 600 })} />
        <Act label="Composer 0 / 96" run={() => lab.setComposerInset(lab.composerInset.peek() > 0 ? 0 : 96)} />
        <Act label="Focus the list" run={() => lab.surface.focus()} />
      </Group>
    </div>
  )
}

function Appearance() {
  const [theme, setTheme] = useState<Theme>(initialTheme)
  const [dir, setDir] = useState<Dir>(initialDir)
  return (
    <Group title="Appearance">
      {(["system", "light", "dark"] as const).map((value) => (
        <Button
          key={value}
          size="small"
          variant={theme === value ? "primary" : "secondary"}
          onClick={() => {
            setTheme(value)
            applyTheme(value)
          }}
        >
          {value}
        </Button>
      ))}
      {(["ltr", "rtl"] as const).map((value) => (
        <Button
          key={value}
          size="small"
          variant={dir === value ? "primary" : "secondary"}
          onClick={() => {
            setDir(value)
            applyDir(value)
          }}
        >
          {value}
        </Button>
      ))}
    </Group>
  )
}

function Status() {
  const status = useSignal(lab.status)
  const mode = useSignal(lab.controller.mode)
  const log = useSignal(lab.core.requestLog)
  return (
    <p role="status" {...stylex.props(pageStyles.status, status.state === "error" && pageStyles.fail)}>
      {status.state}: {status.message} · mode {mode} · requests {log.slice(-4).join(", ") || "none"}
    </p>
  )
}

function Results() {
  const results = useSignal(lab.results)
  if (results.length === 0) return <p {...stylex.props(pageStyles.muted)}>No results yet. Run all, or one operation.</p>
  return (
    <>
      <div {...stylex.props(pageStyles.tableWrap)}>
        <table data-timeline-lab-results="" {...stylex.props(pageStyles.table)}>
          <thead>
            <tr>
              {["Operation", "Metric", "Reps", "Max |drift| px", "Accumulated px", "List", "Rows", "Lab rows", "Mode", "Result"].map((h) => (
                <th key={h} {...stylex.props(pageStyles.cell, pageStyles.head)}>
                  {h}
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {results.map((r, index) => (
              <tr key={`${r.operation}-${index}`}>
                <td {...stylex.props(pageStyles.cell)}>{r.operation}</td>
                <td {...stylex.props(pageStyles.cell)}>{r.metric}</td>
                <td {...stylex.props(pageStyles.cell, pageStyles.number)}>{r.repetitions}</td>
                <td {...stylex.props(pageStyles.cell, pageStyles.number)}>{r.maxAbsDrift}</td>
                <td {...stylex.props(pageStyles.cell, pageStyles.number)}>{r.accumulatedDrift}</td>
                <td {...stylex.props(pageStyles.cell, pageStyles.number)}>{r.renders.list}</td>
                <td {...stylex.props(pageStyles.cell, pageStyles.number)}>{r.renders.rows}</td>
                <td {...stylex.props(pageStyles.cell, pageStyles.number)}>{r.renders.labRows}</td>
                <td {...stylex.props(pageStyles.cell)}>
                  {r.modeBefore} → {r.modeAfter}
                </td>
                <td {...stylex.props(pageStyles.cell, r.pass ? pageStyles.pass : pageStyles.fail)}>
                  {r.pass ? "pass" : `fail: ${r.failures.join("; ")}`}
                  {r.notes.length ? <div {...stylex.props(pageStyles.muted)}>{r.notes.join("; ")}</div> : null}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <details>
        <summary>As text</summary>
        <pre {...stylex.props(pageStyles.pre)}>{resultsAsText(results)}</pre>
      </details>
    </>
  )
}

function LabPage() {
  return (
    <main {...stylex.props(pageStyles.page)}>
      <section {...stylex.props(pageStyles.panel)}>
        <h1 {...stylex.props(pageStyles.title)}>Timeline lab</h1>
        <p {...stylex.props(pageStyles.muted)}>
          Seed {seed}, device pixel ratio {globalThis.devicePixelRatio}. Budget: under {DRIFT_BUDGET_PX} px after each operation and
          nothing accumulating. Keep this window in front while it runs: hidden windows get no animation frames.
        </p>
        <Appearance />
        <Controls />
        <Status />
        <Results />
      </section>
      <Frame lab={lab} />
    </main>
  )
}

// ---------------------------------------------------------------------------
// Styles

const dynamic = stylex.create({
  blockSize: (px: number) => ({ blockSize: `${px}px` }),
})

const rowStyles = stylex.create({
  message: {
    paddingInline: space.xl,
    paddingBlock: space.xxs,
  },
  groupStart: {
    paddingBlockStart: space.md,
  },
  sender: {
    display: "flex",
    gap: space.sm,
    alignItems: "baseline",
    fontSize: font.sizeCallout,
  },
  name: { fontWeight: font.weightSemibold, color: color.label },
  nameOut: { fontWeight: font.weightSemibold, color: color.accent },
  time: { color: color.tertiaryLabel, fontVariantNumeric: "tabular-nums" },
  text: {
    margin: 0,
    overflowWrap: "anywhere",
    whiteSpace: "pre-wrap",
  },
  stream: { color: color.secondaryLabel },
  media: {
    inlineSize: "min(320px, 100%)",
    borderRadius: radius.content,
    backgroundColor: color.controlTrack,
  },
  mediaShown: { marginBlockStart: space.sm },
  extra: {
    inlineSize: "100%",
    backgroundImage: `repeating-linear-gradient(45deg, ${color.quaternaryLabel} 0 4px, transparent 4px 8px)`,
  },
  day: {
    display: "flex",
    justifyContent: "center",
    paddingBlock: space.md,
  },
  dayLabel: {
    paddingInline: space.md,
    paddingBlock: space.xxs,
    borderRadius: radius.pill,
    backgroundColor: color.controlHover,
    color: color.secondaryLabel,
    fontSize: font.sizeCallout,
    fontWeight: font.weightMedium,
  },
  unread: {
    display: "flex",
    alignItems: "center",
    gap: space.md,
    paddingInline: space.xl,
    paddingBlock: space.md,
    color: color.accent,
    fontSize: font.sizeCallout,
    fontWeight: font.weightSemibold,
  },
  unreadRule: { flexGrow: 1, blockSize: "1px", backgroundColor: color.accent, opacity: 0.4 },
  unreadLabel: { flexShrink: 0 },
})

const pageStyles = stylex.create({
  page: {
    display: "flex",
    flexWrap: "wrap",
    alignItems: "flex-start",
    gap: space.xxl,
    boxSizing: "border-box",
    minBlockSize: "100vh",
    padding: space.xl,
    backgroundColor: color.sidebarBackground,
    color: color.label,
    fontFamily: font.familySystem,
    fontSize: font.sizeBody,
  },
  panel: {
    display: "flex",
    flexDirection: "column",
    gap: space.lg,
    flexGrow: 1,
    flexBasis: "520px",
    minInlineSize: 0,
  },
  title: { margin: 0, fontSize: font.sizeTitle2, fontWeight: font.weightSemibold },
  controls: { display: "flex", flexDirection: "column", gap: space.md },
  group: {
    margin: 0,
    paddingInline: space.md,
    paddingBlock: space.sm,
    borderWidth: "1px",
    borderStyle: "solid",
    borderColor: color.separator,
    borderRadius: radius.control,
  },
  legend: { color: color.secondaryLabel, fontSize: font.sizeCallout, paddingInline: space.xs },
  buttons: { display: "flex", flexWrap: "wrap", gap: space.xs },
  status: { margin: 0, color: color.secondaryLabel, fontVariantNumeric: "tabular-nums" },
  muted: { margin: 0, color: color.secondaryLabel, fontSize: font.sizeCallout },
  tableWrap: { overflowX: "auto", maxInlineSize: "100%" },
  table: { borderCollapse: "collapse", fontSize: font.sizeCallout, inlineSize: "100%" },
  cell: {
    paddingInline: space.sm,
    paddingBlock: space.xs,
    borderBlockEndWidth: "1px",
    borderBlockEndStyle: "solid",
    borderBlockEndColor: color.separator,
    textAlign: "start",
    verticalAlign: "top",
  },
  head: { color: color.secondaryLabel, fontWeight: font.weightMedium, whiteSpace: "nowrap" },
  number: { textAlign: "end", fontVariantNumeric: "tabular-nums" },
  pass: { color: color.green },
  fail: { color: color.red },
  pre: { overflowX: "auto", fontFamily: font.familyMono, fontSize: font.sizeCaption },
  frame: {
    position: "relative",
    flexShrink: 0,
    boxSizing: "border-box",
    inlineSize: "var(--lab-frame-inline-size, 560px)",
    blockSize: "var(--lab-frame-block-size, 600px)",
    maxInlineSize: "100%",
    overflow: "hidden",
    borderWidth: "1px",
    borderStyle: "solid",
    borderColor: color.separator,
    borderRadius: radius.content,
  },
  composer: {
    position: "absolute",
    insetInline: 0,
    insetBlockEnd: 0,
    zIndex: 2,
    pointerEvents: "none",
    backgroundColor: `color-mix(in srgb, ${color.windowBackground} 70%, transparent)`,
    backdropFilter: "blur(12px)",
    borderBlockStartWidth: "1px",
    borderBlockStartStyle: "solid",
    borderBlockStartColor: color.separator,
  },
})

// ---------------------------------------------------------------------------
// Start

const container = document.getElementById("root")
if (container) createRoot(container).render(<LabPage />)
if (params.get("run") === "all") void control.runAll()
