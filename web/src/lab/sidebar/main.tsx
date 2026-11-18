/**
 * Sidebar lab: `SidebarView` over a real `SidebarModel`, store client and
 * scheduler, fed by a stand-in core (lab-core.ts) through the scripted
 * endpoint. The strip changes one chat, reorders, pins, switches mode,
 * scales to 5,000 chats and sets density, appearance and direction; the
 * panel shows how many rows the last operation rendered.
 *
 * Driving it: `globalThis.__sidebarLab` is the state as plain data and
 * `globalThis.__sidebarLabControl` the operations (each returns a promise of
 * `{ name, rows, lists, total, ms }`). No StrictMode: it doubles render counts.
 *
 * Query parameters: lab-sidebar.html?count=5000&theme=dark&dir=rtl&density=compact
 */

import { useSignal } from "@inline/reactive/react"
import { createRenderCounter } from "@inline/reactive/react/testing"
import { color } from "@inline/ui/tokens/color.stylex"
import { font } from "@inline/ui/tokens/font.stylex"
import { radius } from "@inline/ui/tokens/radius.stylex"
import { space } from "@inline/ui/tokens/space.stylex"
import * as stylex from "@stylexjs/stylex"
import type { ReactNode } from "react"
import { createRoot } from "react-dom/client"
import { SidebarView, type SidebarDensity, type UnreadStyle } from "../../features/sidebar"
import type { Latency } from "./lab-core"
import { applyDir, applyTheme, SidebarLab, type LabDir, type LabTheme } from "./lab-model"

if (import.meta.env.DEV) {
  void import("virtual:stylex:runtime")
}

const params = new URLSearchParams(location.search)
const initialCount = Math.max(0, Math.min(20_000, Number(params.get("count") ?? 300) || 0))
const counter = createRenderCounter()
const lab = new SidebarLab(counter, initialCount)
const initialTheme: LabTheme = params.get("theme") === "dark" ? "dark" : params.get("theme") === "light" ? "light" : "system"
const initialDir: LabDir = params.get("dir") === "rtl" ? "rtl" : "ltr"
lab.setTheme(initialTheme)
lab.setDir(initialDir)
if (params.get("density") === "compact") lab.density.set("compact")
applyTheme(initialTheme)
applyDir(initialDir)

;(globalThis as { __sidebarLabControl?: unknown }).__sidebarLabControl = lab.control()

function Lab() {
  const session = useSignal(lab.session)
  const density = useSignal(lab.density)
  const unreadStyle = useSignal(lab.unreadStyle)
  const chrome = useSignal(lab.chrome)
  return (
    <div {...stylex.props(styles.page)}>
      <ControlStrip />
      <div {...stylex.props(styles.main)}>
        <div data-lab-stage="" {...stylex.props(styles.stage)}>
          <SidebarView
            model={session.model}
            density={density}
            unreadStyle={unreadStyle}
            ready={lab.ready}
            actions={lab.actions}
            typingFor={lab.typingFor}
            onOpened={lab.onOpened}
            handle={lab.handle}
            header={chrome ? <StageHeader /> : undefined}
            footer={chrome ? <StageFooter /> : undefined}
          />
        </div>
        <Panel />
      </div>
    </div>
  )
}

function StageHeader() {
  return (
    <div {...stylex.props(styles.stageHeader)}>
      <strong>Inline</strong>
      <span {...stylex.props(styles.muted)}>header slot</span>
    </div>
  )
}

function StageFooter() {
  return <div {...stylex.props(styles.stageFooter, styles.muted)}>footer slot</div>
}

function ControlStrip() {
  const density = useSignal(lab.density)
  const unreadStyle = useSignal(lab.unreadStyle)
  const theme = useSignal(lab.theme)
  const dir = useSignal(lab.dir)
  const latency = useSignal(lab.latency)
  const position = useSignal(lab.position)
  const chrome = useSignal(lab.chrome)
  const session = useSignal(lab.session)
  const mode = useSignal(session.model.mode)
  return (
    <header {...stylex.props(styles.strip)}>
      <h1 {...stylex.props(styles.title)}>Sidebar lab</h1>
      <Group label="Row">
        <input
          type="number"
          min={1}
          value={position}
          aria-label="List position the row operations act on"
          onChange={(event) => lab.position.set(Math.max(1, Number(event.currentTarget.value) || 1))}
          {...stylex.props(styles.number)}
        />
        <Action onClick={() => lab.newMessage()}>New message</Action>
        <Action onClick={() => lab.outgoingMessage()}>Sent message</Action>
        <Action onClick={() => lab.unreadUp()}>Unread +1</Action>
        <Action onClick={() => lab.markRead()}>Mark read</Action>
        <Action onClick={() => lab.toggleMark()}>Unread mark</Action>
        <Action onClick={() => lab.draft()}>Draft</Action>
        <Action onClick={() => lab.clearDraft()}>Clear draft</Action>
        <Action onClick={() => lab.togglePin()}>Pin / unpin</Action>
        <Action onClick={() => lab.rename()}>Rename</Action>
        <Action onClick={() => lab.typing()}>Typing</Action>
        <Action onClick={() => lab.typing(undefined, "recording")}>Recording</Action>
        <Action onClick={() => lab.typing(undefined, "working")}>Working</Action>
        <Action onClick={() => lab.stopTyping()}>Stop typing</Action>
        <Action onClick={() => lab.close()}>Close</Action>
        <Action onClick={() => lab.open()}>Open</Action>
      </Group>
      <Group label="List">
        <Action onClick={() => lab.reorder()}>Reorder visible</Action>
        <Action onClick={() => lab.scale(50)}>50</Action>
        <Action onClick={() => lab.scale(500)}>500</Action>
        <Action onClick={() => lab.scale(5000)}>5,000</Action>
        <Action onClick={() => lab.scale(0)}>Empty</Action>
        <Action onClick={() => lab.restart()}>Restart</Action>
        <Action onClick={() => void lab.scrollTest()}>Scroll test (fling)</Action>
        <Action onClick={() => void lab.scrollTest(120, 20)}>Scroll test (slow)</Action>
        <Action onClick={() => lab.focusSidebar()}>Focus sidebar</Action>
      </Group>
      <Choice<"inbox" | "all">
        label="Mode"
        value={mode === "all" ? "all" : "inbox"}
        options={["inbox", "all"]}
        onChange={(value) => void lab.setMode(value)}
      />
      <Choice<string>
        label="Core latency"
        value={String(latency)}
        options={["0", "400", "2000", "never"]}
        onChange={(value) => lab.setLatency((value === "never" ? "never" : Number(value)) as Latency)}
      />
      <Choice<SidebarDensity> label="Density" value={density} options={["standard", "compact"]} onChange={(v) => void lab.setDensity(v)} />
      <Choice<UnreadStyle> label="Unread" value={unreadStyle} options={["count", "dot"]} onChange={(v) => void lab.setUnreadStyle(v)} />
      <Choice<LabTheme> label="Appearance" value={theme} options={["system", "light", "dark"]} onChange={(v) => lab.setTheme(v)} />
      <Choice<LabDir> label="Direction" value={dir} options={["ltr", "rtl"]} onChange={(v) => lab.setDir(v)} />
      <label {...stylex.props(styles.check)}>
        <input type="checkbox" checked={chrome} onChange={(event) => lab.chrome.set(event.currentTarget.checked)} />
        Header and footer
      </label>
    </header>
  )
}

function Panel() {
  const last = useSignal(lab.lastOp)
  const scroll = useSignal(lab.lastScroll)
  const session = useSignal(lab.session)
  const count = useSignal(session.core.count)
  const listed = useSignal(session.model.items).length
  const ready = useSignal(session.core.ready)
  const destination = useSignal(session.workspace.focusedDestination)
  const panes = useSignal(session.workspace.panes).length
  const log = useSignal(lab.log)
  return (
    <aside {...stylex.props(styles.panel)}>
      <h2 {...stylex.props(styles.panelTitle)}>Last operation</h2>
      <dl {...stylex.props(styles.stats)}>
        <dt>Operation</dt>
        <dd>{last?.name ?? "none"}</dd>
        <dt>Rows rendered</dt>
        <dd data-lab-rows="">{last?.rows ?? 0}</dd>
        <dt>List renders</dt>
        <dd>{last?.lists ?? 0}</dd>
        <dt>Components rendered</dt>
        <dd>{last?.total ?? 0}</dd>
        <dt>Time to commit</dt>
        <dd>{last ? `${last.ms} ms` : "none"}</dd>
      </dl>
      <h2 {...stylex.props(styles.panelTitle)}>Scroll test</h2>
      <dl {...stylex.props(styles.stats)}>
        <dt>Frames, step</dt>
        <dd>{scroll ? `${scroll.frames} frames, ${scroll.step} px a frame` : "not run"}</dd>
        <dt>Frame (median / p95 / max)</dt>
        <dd>{scroll ? `${scroll.frameMs.median} / ${scroll.frameMs.p95} / ${scroll.frameMs.max} ms` : "not run"}</dd>
        <dt>Script per frame (median / p95 / max)</dt>
        <dd>{scroll ? `${scroll.scriptMs.median} / ${scroll.scriptMs.p95} / ${scroll.scriptMs.max} ms` : "not run"}</dd>
        <dt>Long animation frames</dt>
        <dd>
          {scroll
            ? scroll.longFrames.supported
              ? `${scroll.longFrames.count} (max ${scroll.longFrames.maxMs} ms, ${scroll.longFrames.scriptMs} ms script)`
              : "not reported by this browser"
            : "not run"}
        </dd>
        <dt>Rows rendered (scroll / max per frame / fill-in)</dt>
        <dd>{scroll ? `${scroll.rowsRendered} / ${scroll.maxRowsInOneFrame} / ${scroll.fillRows}` : "not run"}</dd>
        <dt>Options visible in the DOM (max)</dt>
        <dd>{scroll ? scroll.maxRenderedAtOnce : "not run"}</dd>
      </dl>
      <h2 {...stylex.props(styles.panelTitle)}>State</h2>
      <dl {...stylex.props(styles.stats)}>
        <dt>Chats / listed</dt>
        <dd>
          {count} / {listed}
        </dd>
        <dt>Core answered</dt>
        <dd>{ready ? "yes" : "no"}</dd>
        <dt>Focused pane shows</dt>
        <dd>{describe(destination)}</dd>
        <dt>Panes</dt>
        <dd>{panes}</dd>
      </dl>
      <h2 {...stylex.props(styles.panelTitle)}>Events</h2>
      <ul {...stylex.props(styles.log)}>
        {log.map((line, index) => (
          <li key={`${index}-${line}`}>{line}</li>
        ))}
      </ul>
      <p {...stylex.props(styles.hint)}>
        Keyboard: Tab into the list, arrows, Home, End, Page keys, type a title, Enter or Space to open (with ⌘ or Ctrl
        for a new tab, Option or Alt for the other pane), Shift+F10 or the context menu key for actions.
      </p>
    </aside>
  )
}

const describe = (destination: { kind: string; chatId?: string }): string =>
  destination.chatId ? `${destination.kind} ${destination.chatId}` : destination.kind

function Group(props: { label: string; children: ReactNode }) {
  return (
    <fieldset {...stylex.props(styles.group)}>
      <legend {...stylex.props(styles.legend)}>{props.label}</legend>
      {props.children}
    </fieldset>
  )
}

function Action(props: { onClick: () => unknown; children: ReactNode }) {
  return (
    <button type="button" onClick={() => void props.onClick()} {...stylex.props(styles.button)}>
      {props.children}
    </button>
  )
}

/** The lab's own switcher: plain radio buttons, independent of the kit. */
function Choice<T extends string>(props: { label: string; value: T; options: readonly T[]; onChange: (value: T) => void }) {
  return (
    <fieldset {...stylex.props(styles.group)}>
      <legend {...stylex.props(styles.legend)}>{props.label}</legend>
      {props.options.map((option) => (
        <label key={option} {...stylex.props(styles.check)}>
          <input
            type="radio"
            name={props.label}
            value={option}
            checked={props.value === option}
            onChange={() => props.onChange(option)}
          />
          {option}
        </label>
      ))}
    </fieldset>
  )
}

const styles = stylex.create({
  page: {
    position: "fixed",
    inset: 0,
    display: "flex",
    flexDirection: "column",
    backgroundColor: color.windowBackground,
    color: color.label,
    fontFamily: font.familySystem,
    fontSize: font.sizeBody,
    lineHeight: font.lineHeightBody,
  },
  strip: {
    flexShrink: 0,
    display: "flex",
    flexWrap: "wrap",
    alignItems: "center",
    gap: space.md,
    paddingBlock: space.sm,
    paddingInline: space.lg,
    borderBlockEndWidth: "1px",
    borderBlockEndStyle: "solid",
    borderBlockEndColor: color.separator,
  },
  title: { margin: 0, fontSize: font.sizeTitle3, fontWeight: font.weightSemibold },
  main: { flexGrow: 1, minHeight: 0, display: "flex" },
  stage: {
    flexShrink: 0,
    width: "280px",
    minHeight: 0,
    borderInlineEndWidth: "1px",
    borderInlineEndStyle: "solid",
    borderInlineEndColor: color.separator,
  },
  stageHeader: {
    display: "flex",
    alignItems: "baseline",
    justifyContent: "space-between",
    height: "38px",
    paddingInline: "17px",
    boxSizing: "border-box",
    paddingBlockStart: "12px",
  },
  stageFooter: { paddingBlock: space.md, paddingInline: "17px" },
  muted: { color: color.secondaryLabel, fontSize: font.sizeCallout },
  panel: { flexGrow: 1, minWidth: 0, overflow: "auto", paddingBlock: space.lg, paddingInline: space.xl },
  panelTitle: { marginBlock: `${space.lg} ${space.xs}`, marginInline: 0, fontSize: font.sizeHeadline, fontWeight: font.weightSemibold },
  stats: {
    display: "grid",
    gridTemplateColumns: "max-content 1fr",
    columnGap: space.lg,
    rowGap: space.xxs,
    margin: 0,
    fontVariantNumeric: "tabular-nums",
  },
  log: { margin: 0, paddingInlineStart: space.xl, color: color.secondaryLabel, fontSize: font.sizeCallout },
  hint: { marginBlockStart: space.xl, color: color.secondaryLabel, fontSize: font.sizeCallout, maxWidth: "520px" },
  group: {
    display: "inline-flex",
    flexWrap: "wrap",
    alignItems: "center",
    gap: space.xs,
    margin: 0,
    paddingBlock: space.xxs,
    paddingInline: space.sm,
    borderWidth: "1px",
    borderStyle: "solid",
    borderColor: color.separator,
    borderRadius: radius.control,
  },
  legend: { float: "inline-start", marginInlineEnd: space.xs, color: color.secondaryLabel, fontSize: font.sizeCallout },
  check: { display: "inline-flex", alignItems: "center", gap: space.xxs, fontSize: font.sizeCallout },
  button: { fontSize: font.sizeCallout },
  number: { width: "56px" },
})

const root = document.getElementById("root")
if (!root) throw new Error("Missing #root")
createRoot(root).render(<Lab />)
