/**
 * Content lab: every media kind, block kind and status, attachment, button,
 * service row and header, inside real message rows; a streaming block with
 * per-block render counts; and a height check that measures each row before
 * and after its media loads. Every byte is made in the page (canvas, WAV,
 * recorded WebM); nothing is fetched.
 *
 * Query parameters set the starting state for screenshots:
 *   lab-content.html?appearance=dark&theme=pink&dir=rtl
 *
 * Controls for automation: `globalThis.__contentLabControl` (see README).
 * No StrictMode here, so the render counts are real renders.
 */

import * as stylex from "@stylexjs/stylex"
import type { MessageRow, MessageRowId } from "@inline/core-protocol"
import { useSignal } from "@inline/reactive/react"
import { type Appearance, THEME_IDS, THEME_TITLES, type ThemeId } from "@inline/ui/theme"
import { startDocumentAppearance } from "@inline/ui/theme/stylex"
import { color } from "@inline/ui/tokens/color.stylex"
import { font } from "@inline/ui/tokens/font.stylex"
import { space } from "@inline/ui/tokens/space.stylex"
import { memo, useState } from "react"
import { createRoot } from "react-dom/client"
import { createTimeFormatter } from "@inline/chat-ui"
import { type ContentEnv, MessageContent, ServiceRow } from "../../features/content"
import { createMessageTimes, type MessageRowContext, MessageRowSignalView, presentSender } from "../../features/message"
import { userById } from "./fixtures"
import { ContentLab, labHasContent, STREAM_ROW_ID } from "./lab-model"

if (import.meta.env.DEV) {
  void import("virtual:stylex:runtime")
}

const appearance = startDocumentAppearance()
const params = new URLSearchParams(location.search)
const startAppearance = params.get("appearance")
if (startAppearance === "light" || startAppearance === "dark" || startAppearance === "system") appearance.setAppearance(startAppearance)
const startTheme = params.get("theme")
if (startTheme && (THEME_IDS as readonly string[]).includes(startTheme)) appearance.setTheme(startTheme as ThemeId)
document.documentElement.dir = params.get("dir") === "rtl" ? "rtl" : "ltr"

const lab = new ContentLab()
const times = createMessageTimes(createTimeFormatter())

// ---------------------------------------------------------------------------
// Automation surface

const control = {
  setAppearance: (value: Appearance) => appearance.setAppearance(value),
  setTheme: (value: ThemeId) => appearance.setTheme(value),
  setDirection: (value: "ltr" | "rtl") => {
    document.documentElement.dir = value
  },
  setCanApprove: (value: boolean) => lab.setCanApprove(value),
  setSlowDelay: (ms: number) => {
    lab.slowDelay = ms
  },
  reloadMedia: () => lab.reload(),
  checkHeights: () => lab.checkHeights(),
  startStream: (rate = 30) => lab.startStream(rate),
  stopStream: () => lab.stopStream(),
  resetStream: () => lab.resetStream(),
  streamCounts: () => lab.streamCounts(),
}

Object.assign(globalThis, {
  __contentLab: {
    get log() {
      return lab.log.peek()
    },
    get heights() {
      return lab.heights.peek()
    },
    get streaming() {
      return lab.streaming.peek()
    },
    get blockRenders() {
      return Object.fromEntries(lab.blockRenders)
    },
    get rows() {
      return lab.sections.flatMap((section) => section.fixtures.map((fixture) => ({ section: section.id, id: fixture.row.id, title: fixture.title })))
    },
  },
  __contentLabControl: control,
})

// ---------------------------------------------------------------------------
// Rows

const contexts = new WeakMap<ContentEnv, MessageRowContext>()
const contextFor = (env: ContentEnv): MessageRowContext => {
  let context = contexts.get(env)
  if (!context) {
    context = {
      times,
      isDM: false,
      handlers: env.handlers,
      renderContent: (display: MessageRow) =>
        labHasContent(lab, display) ? <MessageContent message={lab.full(display.id) ?? display} env={env} /> : null,
    }
    contexts.set(env, context)
  }
  return context
}

const LabRow = memo(function LabRow(props: { rowId: MessageRowId; title: string; context: MessageRowContext }) {
  const initial = lab.full(props.rowId)
  const sender = initial && !initial.out ? userById.get(initial.fromId) : undefined
  return (
    <figure {...stylex.props(styles.fixture)}>
      <figcaption {...stylex.props(styles.caption)}>{props.title}</figcaption>
      <MessageRowSignalView
        row={lab.display(props.rowId)}
        firstInGroup
        lastInGroup
        context={props.context}
        sender={sender ? presentSender(sender) : undefined}
      />
    </figure>
  )
})

function Gallery(props: { context: MessageRowContext }) {
  const generation = useSignal(lab.generation)
  return (
    <div key={generation} data-lab-measure="" {...stylex.props(styles.gallery)}>
      {lab.sections.map((section) => (
        <section key={section.id} aria-labelledby={`section-${section.id}`} {...stylex.props(styles.section)}>
          <h2 id={`section-${section.id}`} {...stylex.props(styles.sectionTitle)}>
            {section.title}
          </h2>
          {section.fixtures.map((fixture) => (
            <LabRow key={fixture.row.id} rowId={fixture.row.id} title={fixture.title} context={props.context} />
          ))}
        </section>
      ))}
    </div>
  )
}

function Services(props: { env: ContentEnv }) {
  return (
    <section aria-labelledby="section-service" {...stylex.props(styles.section)}>
      <h2 id="section-service" {...stylex.props(styles.sectionTitle)}>
        Service rows
      </h2>
      {lab.services.map((fixture) => (
        <figure key={fixture.row.id} {...stylex.props(styles.fixture)}>
          <figcaption {...stylex.props(styles.caption)}>{fixture.title}</figcaption>
          <ServiceRow message={fixture.row} env={props.env} />
        </figure>
      ))}
    </section>
  )
}

function Streaming(props: { context: MessageRowContext }) {
  const streaming = useSignal(lab.streaming)
  return (
    <section aria-labelledby="section-stream" {...stylex.props(styles.section)}>
      <h2 id="section-stream" {...stylex.props(styles.sectionTitle)}>
        Streaming blocks
      </h2>
      <p {...stylex.props(styles.hint)}>
        Each update appends a word to the last paragraph or starts a new one. Only the growing block should count up; the
        heading and the earlier paragraphs stay at their first count.
      </p>
      <div {...stylex.props(styles.controls)}>
        <button type="button" onClick={() => (streaming ? lab.stopStream() : lab.startStream(30))}>
          {streaming ? "Stop" : "Start at 30/s"}
        </button>
        <button type="button" disabled={streaming} onClick={() => lab.startStream(60)}>
          Start at 60/s
        </button>
        <button type="button" onClick={() => lab.resetStream()}>
          Reset
        </button>
      </div>
      <div {...stylex.props(styles.streamLayout)}>
        <div {...stylex.props(styles.streamRow)}>
          <LabRow rowId={STREAM_ROW_ID} title="Agent message" context={props.context} />
        </div>
        <pre aria-label="Renders per block" ref={lab.countsTarget} {...stylex.props(styles.counts)} />
      </div>
    </section>
  )
}

function Heights() {
  const results = useSignal(lab.heights)
  const checking = useSignal(lab.checking)
  return (
    <section aria-labelledby="section-heights" {...stylex.props(styles.section)}>
      <h2 id="section-heights" {...stylex.props(styles.sectionTitle)}>
        Height check
      </h2>
      <p {...stylex.props(styles.hint)}>
        Reloads every source on hold, measures each row and media box, releases the loads, waits, and measures again.
        Before and after must be equal.
      </p>
      <div {...stylex.props(styles.controls)}>
        <button type="button" disabled={checking} onClick={() => void lab.checkHeights()}>
          {checking ? "Checking…" : "Check heights"}
        </button>
      </div>
      {results && (
        <table {...stylex.props(styles.results)}>
          <thead>
            <tr>
              <th scope="col">Row</th>
              <th scope="col">Before</th>
              <th scope="col">After</th>
              <th scope="col">Media boxes (before → after)</th>
              <th scope="col">Equal</th>
            </tr>
          </thead>
          <tbody>
            {results.map((result) => (
              <tr key={result.rowId} data-equal={result.equal}>
                <td>{result.title}</td>
                <td {...stylex.props(styles.number)}>{result.before.toFixed(1)}</td>
                <td {...stylex.props(styles.number)}>{result.after.toFixed(1)}</td>
                <td {...stylex.props(styles.number)}>
                  {result.media.map((box) => `${box.before.toFixed(1)} → ${box.after.toFixed(1)}`).join(", ")}
                </td>
                <td {...stylex.props(result.equal ? styles.pass : styles.fail)}>{result.equal ? "yes" : "NO"}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </section>
  )
}

function Log() {
  const text = useSignal(lab.log)
  return (
    <output aria-live="polite" {...stylex.props(styles.log)}>
      {text}
    </output>
  )
}

// ---------------------------------------------------------------------------
// Page

function Lab() {
  const env = useSignal(lab.env)
  const mode = useSignal(appearance.appearance)
  const theme = useSignal(appearance.theme)
  const canApprove = useSignal(lab.canApprove)
  const [dir, setDir] = useState(document.documentElement.dir === "rtl" ? "rtl" : "ltr")
  const context = contextFor(env)
  return (
    <div {...stylex.props(styles.page)}>
      <header {...stylex.props(styles.header)}>
        <h1 {...stylex.props(styles.title)}>Content lab</h1>
        <label {...stylex.props(styles.check)}>
          Appearance
          <select value={mode} onChange={(event) => appearance.setAppearance(event.currentTarget.value as Appearance)}>
            <option value="system">System</option>
            <option value="light">Light</option>
            <option value="dark">Dark</option>
          </select>
        </label>
        <label {...stylex.props(styles.check)}>
          Theme
          <select value={theme} onChange={(event) => appearance.setTheme(event.currentTarget.value as ThemeId)}>
            {THEME_IDS.map((id) => (
              <option key={id} value={id}>
                {THEME_TITLES[id]}
              </option>
            ))}
          </select>
        </label>
        <label {...stylex.props(styles.check)}>
          Direction
          <select
            value={dir}
            onChange={(event) => {
              const next = event.currentTarget.value === "rtl" ? "rtl" : "ltr"
              document.documentElement.dir = next
              setDir(next)
            }}
          >
            <option value="ltr">Left to right</option>
            <option value="rtl">Right to left</option>
          </select>
        </label>
        <label {...stylex.props(styles.check)}>
          <input type="checkbox" checked={canApprove} onChange={(event) => lab.setCanApprove(event.currentTarget.checked)} />
          Viewer can approve
        </label>
        <label {...stylex.props(styles.check)}>
          Slow loads
          <select defaultValue={String(lab.slowDelay)} onChange={(event) => (lab.slowDelay = Number(event.currentTarget.value))}>
            <option value="600">0.6 s</option>
            <option value="1500">1.5 s</option>
            <option value="4000">4 s</option>
          </select>
        </label>
        <button type="button" onClick={() => lab.reload()}>
          Reload media
        </button>
        <Log />
      </header>
      <main {...stylex.props(styles.main)}>
        <Heights />
        <Streaming context={context} />
        <Gallery context={context} />
        <Services env={env} />
      </main>
    </div>
  )
}

const styles = stylex.create({
  page: {
    minBlockSize: "100vh",
    backgroundColor: color.windowBackground,
    color: color.label,
    fontFamily: font.familySystem,
    fontSize: font.sizeBody,
    lineHeight: font.lineHeightBody,
  },
  header: {
    position: "sticky",
    insetBlockStart: 0,
    zIndex: 2,
    display: "flex",
    flexWrap: "wrap",
    alignItems: "center",
    gap: space.lg,
    paddingBlock: space.md,
    paddingInline: space.xl,
    backgroundColor: color.sidebarBackground,
    borderBlockEndWidth: "1px",
    borderBlockEndStyle: "solid",
    borderBlockEndColor: color.separator,
  },
  title: { margin: 0, fontSize: font.sizeTitle3, fontWeight: font.weightSemibold },
  check: { display: "inline-flex", alignItems: "center", gap: space.xs },
  log: {
    flexBasis: "100%",
    color: color.secondaryLabel,
    fontSize: font.sizeCallout,
    whiteSpace: "nowrap",
    overflow: "hidden",
    textOverflow: "ellipsis",
  },
  main: {
    display: "flex",
    flexDirection: "column",
    gap: space.huge,
    paddingBlock: space.xl,
    maxInlineSize: "960px",
    marginInline: "auto",
  },
  gallery: { display: "flex", flexDirection: "column", gap: space.huge },
  section: { display: "flex", flexDirection: "column", gap: space.md },
  sectionTitle: { margin: 0, paddingInline: space.xl, fontSize: font.sizeTitle2, fontWeight: font.weightSemibold },
  hint: { margin: 0, paddingInline: space.xl, color: color.secondaryLabel },
  controls: { display: "flex", gap: space.md, paddingInline: space.xl },
  fixture: {
    margin: 0,
    paddingBlock: space.xs,
    borderBlockStartWidth: "1px",
    borderBlockStartStyle: "solid",
    borderBlockStartColor: color.separator,
  },
  caption: { paddingInline: space.xl, paddingBlockEnd: space.xxs, fontSize: font.sizeCallout, color: color.secondaryLabel },
  streamLayout: { display: "flex", flexWrap: "wrap", gap: space.lg, alignItems: "flex-start" },
  streamRow: { flexGrow: 1, flexBasis: "420px", minInlineSize: 0 },
  counts: {
    margin: 0,
    marginInline: space.xl,
    paddingBlock: space.sm,
    paddingInline: space.md,
    minInlineSize: "200px",
    borderRadius: "6px",
    backgroundColor: color.sidebarBackground,
    fontFamily: font.familyMono,
    fontSize: font.sizeCallout,
  },
  results: { marginInline: space.xl, borderCollapse: "collapse", fontSize: font.sizeCallout },
  number: { fontVariantNumeric: "tabular-nums", paddingInline: space.md },
  pass: { color: color.green, fontWeight: font.weightSemibold },
  fail: { color: color.red, fontWeight: font.weightSemibold },
})

const root = document.getElementById("root")
if (root) createRoot(root).render(<Lab />)
