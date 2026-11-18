/**
 * Quick Search lab: the real palette over a real `AccountSession` fed with
 * generated rows (mixed scripts, long titles, archived chats), the real
 * keyboard dispatcher (Cmd/Ctrl+K opens it), and message and server sources
 * whose delay and failure change live. A render counter shows how many
 * times each part rendered: typing should render only rows whose item
 * changed, and moving the highlight two rows.
 *
 * Query parameters: `?theme=dark|light&dir=rtl&open=1&q=<text>`.
 *
 * For automation: `globalThis.__quickSearchLab` is a snapshot of the state
 * (read it again after each step); `globalThis.__quickSearchLabControl`
 * drives it (open, type, compose, key, shortcut, settings, theme, direction,
 * window width). `remote` is the real server people source's state;
 * `messageColumns` measures the first message hit's title and snippet.
 */

import * as stylex from "@stylexjs/stylex"
import { signal } from "@inline/reactive"
import { useSignal } from "@inline/reactive/react"
import { createRenderCounter } from "@inline/reactive/react/testing"
import { Kbd } from "@inline/ui/react"
import { color } from "@inline/ui/tokens/color.stylex"
import { font } from "@inline/ui/tokens/font.stylex"
import { radius } from "@inline/ui/tokens/radius.stylex"
import { space } from "@inline/ui/tokens/space.stylex"
import type { SpaceID } from "@inline/ids"
import { createRoot } from "react-dom/client"
import { messageTitleMaxWidth, QuickSearchPalette, shortcutKeys } from "../../features/quick-search"
import { parseCombo } from "@inline/view"
import { QuickSearchLab, type LabSettings } from "./lab-model"

if (import.meta.env.DEV) {
  void import("virtual:stylex:runtime")
}

type Theme = "system" | "light" | "dark"
type Dir = "ltr" | "rtl"

const params = new URLSearchParams(location.search)
let theme: Theme = params.get("theme") === "dark" ? "dark" : params.get("theme") === "light" ? "light" : "system"
let dir: Dir = params.get("dir") === "rtl" ? "rtl" : "ltr"

const applyTheme = (next: Theme) => {
  theme = next
  document.documentElement.style.colorScheme = next === "system" ? "light dark" : next
}
const applyDir = (next: Dir) => {
  dir = next
  document.documentElement.dir = next
}
applyTheme(theme)
applyDir(dir)

// Count renders from the first one. Not under StrictMode, which renders twice.
const counter = createRenderCounter()

/** What the switches show; written from event handlers only. */
const appearance = signal<{ theme: Theme; dir: Dir }>({ theme, dir })
const setTheme = (next: Theme) => {
  applyTheme(next)
  appearance.set({ theme, dir })
}
const setDir = (next: Dir) => {
  applyDir(next)
  appearance.set({ theme, dir })
}

const lab = new QuickSearchLab({
  toggleTheme: () => {
    const dark = theme === "dark" || (theme === "system" && matchMedia("(prefers-color-scheme: dark)").matches)
    setTheme(dark ? "light" : "dark")
  },
})

// ---------------------------------------------------------------------------
// Measures: open to paint and keystroke to paint, as `performance` measures.

const afterPaint = (fn: () => void) => requestAnimationFrame(() => setTimeout(fn, 0))
const measure = (name: string) => {
  const start = `${name}:start`
  performance.mark(start)
  afterPaint(() => {
    try {
      performance.measure(name, start)
    } catch {
      // Marks were cleared.
    }
  })
}
const lastMeasure = (name: string): number | undefined => {
  const entries = performance.getEntriesByName(name, "measure")
  return entries[entries.length - 1]?.duration
}

// ---------------------------------------------------------------------------
// Window width: the palette reads `--quick-search-viewport-width` in place of
// 100vw, so the lab can try 480, 750 and 1,280 px windows in any window.

const viewportWidth = signal<number | null>(null)
const setViewportWidth = (px: number | null) => {
  const root = document.documentElement
  if (px === null) root.style.removeProperty("--quick-search-viewport-width")
  else root.style.setProperty("--quick-search-viewport-width", `${px}px`)
  viewportWidth.set(px)
}

/** The first message hit's title and snippet columns, measured. */
const messageColumns = () => {
  const row = document.querySelector<HTMLElement>('[role="option"][data-quick-search-id^="message:"]')
  if (!row) return null
  const title = row.querySelector<HTMLElement>('[data-quick-search-part="title"]')
  const snippet = row.querySelector<HTMLElement>('[data-quick-search-part="secondary"]')
  const column = title?.parentElement
  if (!title || !column) return null
  const em = Number.parseFloat(getComputedStyle(title).fontSize) || 13
  const columnWidth = column.getBoundingClientRect().width
  return {
    id: row.dataset.quickSearchId ?? null,
    palette: dialogElement()?.getBoundingClientRect().width ?? null,
    column: columnWidth,
    title: title.getBoundingClientRect().width,
    titleText: title.textContent ?? "",
    titleTruncated: title.scrollWidth > title.clientWidth + 0.5,
    expectedTitleMax: messageTitleMaxWidth(columnWidth, em),
    snippet: snippet ? snippet.getBoundingClientRect().width : 0,
  }
}

const openPalette = () => {
  measure("quick-search-lab:open-to-paint")
  lab.quickSearch.open()
}

// ---------------------------------------------------------------------------
// Automation

const field = () => document.querySelector<HTMLInputElement>('dialog input[role="combobox"]')
const dialogElement = () => document.querySelector<HTMLDialogElement>("dialog")

const snapshot = () => {
  const model = lab.quickSearch.model
  const input = field()
  const activeDescendant = input?.getAttribute("aria-activedescendant") ?? null
  return {
    isOpen: model.isOpen.peek(),
    dialogOpen: dialogElement()?.open ?? false,
    text: model.text.peek(),
    query: model.query.peek(),
    activeId: model.activeId.peek(),
    emptyState: model.emptyState.peek(),
    messages: model.messagesState.peek().status,
    global: model.globalState.peek().status,
    sections: model.sections.peek().map((section) => ({
      kind: section.kind,
      title: section.title,
      items: section.items.map((item) => ({ id: item.id, kind: item.kind, title: item.title })),
    })),
    focusInField: !!input && document.activeElement === input,
    activeElement: document.activeElement ? `${document.activeElement.tagName.toLowerCase()}${document.activeElement.id ? `#${document.activeElement.id}` : ""}` : null,
    ariaActiveDescendant: activeDescendant,
    activeOptionRendered: activeDescendant ? !!document.getElementById(activeDescendant) : false,
    renderedOptions: document.querySelectorAll('[role="option"]').length,
    destination: lab.session.workspace.focusedDestination.peek(),
    panes: lab.session.workspace.panes.peek().length,
    context: lab.quickSearch.context.peek(),
    outcomes: lab.outcomes.peek(),
    renderCounts: counter.counts(),
    measures: {
      openToPaint: lastMeasure("quick-search-lab:open-to-paint"),
      keystrokeToPaint: lastMeasure("quick-search-lab:keystroke-to-paint"),
    },
    settings: lab.settings.peek(),
    remote: lab.remote.state.peek(),
    remoteStats: lab.remote.stats(),
    viewportWidth: viewportWidth.peek(),
    messageColumns: messageColumns(),
    data: lab.data.counts,
    theme,
    dir,
    platform: lab.platform,
  }
}

const key = (name: string, modifiers: { meta?: boolean; ctrl?: boolean; alt?: boolean; shift?: boolean; composing?: boolean } = {}) => {
  const target = field() ?? document.body
  const event = new KeyboardEvent("keydown", {
    key: name,
    bubbles: true,
    cancelable: true,
    metaKey: !!modifiers.meta,
    ctrlKey: !!modifiers.ctrl,
    altKey: !!modifiers.alt,
    shiftKey: !!modifiers.shift,
    isComposing: !!modifiers.composing,
  })
  target.dispatchEvent(event)
  return event.defaultPrevented
}

const control = {
  open: openPalette,
  close: () => lab.quickSearch.close(),
  toggle: () => lab.quickSearch.toggle(),
  /** Press the platform's Quick Search shortcut on the page (the real dispatcher path). */
  shortcut: () => {
    measure("quick-search-lab:open-to-paint")
    const mac = lab.platform.os === "mac"
    document.body.dispatchEvent(new KeyboardEvent("keydown", { key: "k", code: "KeyK", metaKey: mac, ctrlKey: !mac, bubbles: true, cancelable: true }))
  },
  /** Replace the field's text as typing would (an input event). */
  type: (text: string) => {
    const input = field()
    if (!input) return false
    measure("quick-search-lab:keystroke-to-paint")
    input.value = text
    input.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertText", data: text }))
    return true
  },
  /** An input method composition: nothing may happen until it ends. */
  compose: (steps: readonly string[], commit: string) => {
    const input = field()
    if (!input) return false
    input.dispatchEvent(new CompositionEvent("compositionstart", { bubbles: true, data: "" }))
    for (const step of steps) {
      input.value = step
      input.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertCompositionText", data: step, isComposing: true }))
    }
    input.value = commit
    input.dispatchEvent(new CompositionEvent("compositionend", { bubbles: true, data: commit }))
    return true
  },
  key,
  setSettings: (patch: Partial<LabSettings>) => lab.setSettings(patch),
  /** Lay the palette out as in a window this wide (480, 750, 1280), or null for the real window. */
  setViewportWidth,
  setTheme: (next: Theme) => setTheme(next),
  setDir: (next: Dir) => setDir(next),
  /** Scope results to a space (enables the Create row), or none. */
  setContextSpace: (spaceId: string | null) =>
    lab.focus(spaceId ? { kind: "space", spaceId: spaceId as SpaceID, page: "members" } : { kind: "allChats" }),
  resetRenderCounts: () => counter.reset(),
  clearUsage: () => lab.clearUsage(),
  snapshot,
}

Object.defineProperty(globalThis, "__quickSearchLab", { configurable: true, get: snapshot })
Object.defineProperty(globalThis, "__quickSearchLabControl", { configurable: true, value: control })

// ---------------------------------------------------------------------------
// View

function Lab() {
  const shown = useSignal(appearance)
  const settings = useSignal(lab.settings)
  const outcomes = useSignal(lab.outcomes)
  const open = useSignal(lab.quickSearch.isOpen)
  const query = useSignal(lab.quickSearch.model.query)
  const destination = useSignal(lab.session.workspace.focusedDestination)
  const width = useSignal(viewportWidth)
  const remote = useSignal(lab.remote.state)
  const shortcut = shortcutKeys(parseCombo("Mod+K", lab.platform.os), lab.platform.os)
  return (
    <div {...stylex.props(styles.page)}>
      <header {...stylex.props(styles.header)}>
        <h1 {...stylex.props(styles.title)}>Quick Search lab</h1>
        <button type="button" onClick={openPalette} {...stylex.props(styles.button)}>
          Open Quick Search{" "}
          <span dir="ltr">
            <Kbd keys={shortcut} />
          </span>
        </button>
        <Segmented label="Appearance" value={shown.theme} options={["system", "light", "dark"]} onChange={setTheme} />
        <Segmented label="Direction" value={shown.dir} options={["ltr", "rtl"]} onChange={setDir} />
        <label {...stylex.props(styles.field)}>
          Space
          <select
            onChange={(event) => control.setContextSpace(event.currentTarget.value || null)}
            {...stylex.props(styles.select)}
          >
            <option value="">None</option>
            {lab.data.spaces.map((spaceRow) => (
              <option key={spaceRow.id} value={spaceRow.id}>
                {spaceRow.name}
              </option>
            ))}
          </select>
        </label>
      </header>
      <div {...stylex.props(styles.controls)}>
        <SourceControls
          label="Messages"
          delay={settings.messageDelayMs}
          fail={settings.messageFail}
          onDelay={(ms) => lab.setSettings({ messageDelayMs: ms })}
          onFail={(fail) => lab.setSettings({ messageFail: fail })}
        />
        <SourceControls
          label="Server"
          delay={settings.remoteDelayMs}
          fail={settings.remoteFail}
          onDelay={(ms) => lab.setSettings({ remoteDelayMs: ms })}
          onFail={(fail) => lab.setSettings({ remoteFail: fail })}
        />
        <label {...stylex.props(styles.field)}>
          Server failure
          <select
            value={settings.remoteFailReason}
            onChange={(event) => lab.setSettings({ remoteFailReason: event.currentTarget.value as LabSettings["remoteFailReason"] })}
            {...stylex.props(styles.select)}
          >
            <option value="offline">offline</option>
            <option value="server">server</option>
            <option value="unavailable">unavailable</option>
          </select>
        </label>
        <Segmented
          label="Window width"
          value={width === null ? "window" : String(width)}
          options={["window", "480", "750", "1280"]}
          onChange={(value) => setViewportWidth(value === "window" ? null : Number(value))}
        />
        <label {...stylex.props(styles.field)}>
          <input type="checkbox" checked={settings.remoteEnabled} onChange={(event) => lab.setSettings({ remoteEnabled: event.currentTarget.checked })} />
          Server returns people
        </label>
        <button type="button" onClick={() => lab.clearUsage()} {...stylex.props(styles.button)}>
          Clear usage
        </button>
      </div>
      <main {...stylex.props(styles.main)}>
        <section {...stylex.props(styles.card)}>
          <h2 {...stylex.props(styles.cardTitle)}>State</h2>
          <dl {...stylex.props(styles.facts)}>
            <dt>Open</dt>
            <dd>{open ? "yes" : "no"}</dd>
            <dt>Query</dt>
            <dd dir="auto">{query || "(empty)"}</dd>
            <dt>Focused</dt>
            <dd>{JSON.stringify(destination)}</dd>
            <dt>Server people</dt>
            <dd>{remote.status === "failed" ? `failed (${remote.reason}), quiet` : remote.status === "done" ? `${remote.count} found` : remote.status}</dd>
            <dt>Data</dt>
            <dd>
              {lab.data.counts.chats} chats, {lab.data.counts.people} people, {lab.data.counts.spaces} spaces, {lab.data.counts.messages} messages
            </dd>
          </dl>
        </section>
        <section {...stylex.props(styles.card)}>
          <h2 {...stylex.props(styles.cardTitle)}>Render counts</h2>
          <pre ref={countsRef} {...stylex.props(styles.pre)} />
          <button type="button" onClick={() => counter.reset()} {...stylex.props(styles.button)}>
            Reset counts
          </button>
        </section>
        <section {...stylex.props(styles.card)}>
          <h2 {...stylex.props(styles.cardTitle)}>Performed</h2>
          <ol {...stylex.props(styles.log)}>
            {outcomes.map((text, index) => (
              <li key={`${index}-${text}`} dir="auto">
                {text}
              </li>
            ))}
          </ol>
        </section>
        <section {...stylex.props(styles.card)}>
          <h2 {...stylex.props(styles.cardTitle)}>Try</h2>
          <ul {...stylex.props(styles.log)}>
            <li>Type “de”, “pm”, “ali”, “علی”, “설계”, “rollout”, “zz” (with a space chosen: the Create row).</li>
            <li>Arrows, Home and End on an empty field, Tab and Shift+Tab, Enter, Mod+Enter, Escape, Mod+K.</li>
            <li>Hover rows, then hold the pointer still while typing: the highlight must not jump.</li>
            <li>Set a slow or failing source and watch the bottom of the list; rows above never move. A failing server is quiet: no error line, local people stay.</li>
            <li>Type “rollout” at each window width: a message hit's chat title keeps up to 40% of the column (at least 7em), the snippet takes the rest.</li>
          </ul>
        </section>
      </main>
      <QuickSearchPalette quickSearch={lab.quickSearch} />
    </div>
  )
}

/** The counts are written straight into the element, so showing them renders nothing. */
const countsRef = (element: HTMLPreElement | null) => {
  if (!element) return
  const write = () => {
    const counts = counter.counts()
    element.textContent = Object.keys(counts).length
      ? Object.entries(counts)
          .sort(([a], [b]) => a.localeCompare(b))
          .map(([name, count]) => `${name.padEnd(24)} ${count}`)
          .join("\n")
      : "(no renders yet)"
  }
  write()
  const id = setInterval(write, 250)
  return () => clearInterval(id)
}

function SourceControls(props: { label: string; delay: number; fail: boolean; onDelay: (ms: number) => void; onFail: (fail: boolean) => void }) {
  return (
    <fieldset {...stylex.props(styles.segmented)}>
      <legend {...stylex.props(styles.legend)}>{props.label}</legend>
      <label {...stylex.props(styles.field)}>
        delay
        <input
          type="number"
          min={0}
          step={50}
          value={props.delay}
          onChange={(event) => props.onDelay(Math.max(0, Number(event.currentTarget.value) || 0))}
          {...stylex.props(styles.number)}
        />
        ms
      </label>
      <label {...stylex.props(styles.field)}>
        <input type="checkbox" checked={props.fail} onChange={(event) => props.onFail(event.currentTarget.checked)} />
        fail
      </label>
    </fieldset>
  )
}

/** The lab's own switcher: plain radio buttons. */
function Segmented<T extends string>(props: { label: string; value: T; options: readonly T[]; onChange: (value: T) => void }) {
  return (
    <fieldset {...stylex.props(styles.segmented)}>
      <legend {...stylex.props(styles.legend)}>{props.label}</legend>
      {props.options.map((option) => (
        <label key={option} {...stylex.props(styles.field)}>
          <input type="radio" name={props.label} value={option} checked={props.value === option} onChange={() => props.onChange(option)} />
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
    overflow: "auto",
    backgroundColor: color.windowBackground,
    color: color.label,
    fontFamily: font.familySystem,
    fontSize: font.sizeBody,
    lineHeight: font.lineHeightBody,
  },
  header: {
    position: "sticky",
    top: 0,
    zIndex: 1,
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
  controls: {
    display: "flex",
    flexWrap: "wrap",
    alignItems: "center",
    gap: space.lg,
    paddingBlock: space.md,
    paddingInline: space.xl,
    borderBlockEndWidth: "1px",
    borderBlockEndStyle: "solid",
    borderBlockEndColor: color.separator,
  },
  main: {
    display: "grid",
    gridTemplateColumns: "repeat(auto-fit, minmax(min(100%, 320px), 1fr))",
    gap: space.xl,
    paddingBlock: space.xl,
    paddingInline: space.xl,
  },
  card: {
    display: "flex",
    flexDirection: "column",
    gap: space.md,
    minWidth: 0,
    padding: space.lg,
    borderWidth: "1px",
    borderStyle: "solid",
    borderColor: color.separator,
    borderRadius: radius.content,
  },
  cardTitle: { margin: 0, fontSize: font.sizeHeadline, fontWeight: font.weightSemibold },
  facts: { display: "grid", gridTemplateColumns: "auto 1fr", columnGap: space.md, rowGap: space.xs, margin: 0, overflowWrap: "anywhere" },
  pre: { margin: 0, fontFamily: font.familyMono, fontSize: font.sizeCallout, whiteSpace: "pre-wrap" },
  log: { margin: 0, paddingInlineStart: space.xl, fontSize: font.sizeCallout, overflowWrap: "anywhere" },
  button: {
    display: "inline-flex",
    alignItems: "center",
    gap: space.sm,
    paddingBlock: space.xs,
    paddingInline: space.md,
    fontFamily: "inherit",
    fontSize: font.sizeBody,
    color: color.controlText,
    backgroundColor: color.control,
    borderWidth: "1px",
    borderStyle: "solid",
    borderColor: color.controlBorder,
    borderRadius: radius.control,
  },
  segmented: {
    display: "inline-flex",
    alignItems: "center",
    flexWrap: "wrap",
    gap: space.md,
    margin: 0,
    paddingBlock: space.xxs,
    paddingInline: space.md,
    borderWidth: "1px",
    borderStyle: "solid",
    borderColor: color.separator,
    borderRadius: radius.control,
  },
  legend: { float: "inline-start", marginInlineEnd: space.md, color: color.secondaryLabel },
  field: { display: "inline-flex", alignItems: "center", gap: space.xs },
  number: { width: "64px", fontFamily: "inherit", fontSize: font.sizeBody },
  select: { fontFamily: "inherit", fontSize: font.sizeBody },
})

const root = document.getElementById("root")
if (root) {
  createRoot(root).render(<Lab />)
  const initialQuery = params.get("q")
  if (params.get("open") === "1" || initialQuery) {
    afterPaint(() => {
      openPalette()
      if (initialQuery) afterPaint(() => control.type(initialQuery))
    })
  }
}
