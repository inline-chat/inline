/**
 * Find lab: the real find bar (`FindBar`, `FindInChatModel`, the find
 * commands on the real keyboard dispatcher) over a plain scrolling list of
 * generated messages, with a stand-in core answering `findInChat` and
 * `countMessages` through the real store client. The core's delay, an
 * "indexing" state, failures and thousands of hits (about 2,600 of 4,000
 * messages contain "deploy") change live.
 *
 * Query parameters: `?theme=dark|light&dir=rtl&delay=<ms>&mode=ready|indexing|error|failPaging&server=off|older|fail&messages=<n>&open=1&q=<text>`.
 *
 * For automation: `globalThis.__findLab` is a snapshot of the state (read
 * it again after each step); `globalThis.__findLabControl` drives it.
 */

import type { MessageID } from "@inline/ids"
import { signal } from "@inline/reactive"
import { useElement, useSignal } from "@inline/reactive/react"
import { countRender, createRenderCounter } from "@inline/reactive/react/testing"
import { Kbd } from "@inline/ui/react"
import { color } from "@inline/ui/tokens/color.stylex"
import { font } from "@inline/ui/tokens/font.stylex"
import { radius } from "@inline/ui/tokens/radius.stylex"
import { space } from "@inline/ui/tokens/space.stylex"
import { parseCombo } from "@inline/view"
import * as stylex from "@stylexjs/stylex"
import { memo } from "react"
import { createRoot } from "react-dom/client"
import { FindBar, findCommandIds } from "../../features/find"
import { highlightSegments, shortcutKeys } from "../../features/quick-search/present"
import type { LabCoreMode, LabMessage, LabServerMode } from "./lab-core"
import { FindLab } from "./lab-model"

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

const modes: readonly LabCoreMode[] = ["ready", "indexing", "error", "failPaging"]
const serverModes: readonly LabServerMode[] = ["off", "older", "fail"]
const messageCount = Math.max(10, Math.min(20_000, Number(params.get("messages")) || 4000))
const lab = new FindLab({ messages: messageCount })
const initialDelay = Number(params.get("delay"))
if (Number.isFinite(initialDelay) && params.has("delay")) lab.setDelay(initialDelay)
const initialMode = params.get("mode") as LabCoreMode | null
if (initialMode && modes.includes(initialMode)) lab.setMode(initialMode)
const initialServer = params.get("server") as LabServerMode | null
if (initialServer && serverModes.includes(initialServer)) lab.setServer(initialServer)

/** What the controls show; written from event handlers only. */
const currentSettings = () => ({ theme, dir, delayMs: lab.core.settings.delayMs, mode: lab.core.settings.mode, server: lab.core.settings.server })
const settings = signal(currentSettings())
const updateSettings = () => settings.set(currentSettings())

// ---------------------------------------------------------------------------
// Automation

const field = () => document.querySelector<HTMLInputElement>('[data-find-bar] input[role="combobox"]')
const resultsList = () => document.querySelector<HTMLElement>('[data-find-bar] [role="listbox"]')
const describe = (element: Element | null) =>
  element ? `${element.tagName.toLowerCase()}${element.id ? `#${element.id}` : ""}${element.getAttribute("data-lab") ? `[${element.getAttribute("data-lab")}]` : ""}` : null

const snapshot = () => {
  const model = lab.model
  const input = field()
  const activeDescendant = input?.getAttribute("aria-activedescendant") ?? null
  const current = model.current.peek()
  return {
    status: "ready" as const,
    open: model.isOpen.peek(),
    barRendered: !!document.querySelector("[data-find-bar]"),
    text: model.text.peek(),
    query: model.query.peek(),
    state: model.state.peek(),
    counterText: model.counterText.peek() ?? null,
    position: model.position.peek() ?? null,
    total: model.total.peek() ?? null,
    count: model.count.peek() ?? null,
    hits: model.hits.peek().length,
    /** Of `hits`, those only the server found (not on the device). */
    remoteHits: model.hits.peek().filter((hit) => hit.remote === true).length,
    serverFailed: model.serverFailed.peek(),
    serverSearching: model.serverSearching.peek(),
    serverCount: model.serverCount.peek() ?? null,
    stale: model.stale.peek(),
    currentMessageId: current?.messageId ?? null,
    currentIndex: model.currentIndex.peek() ?? null,
    showsResults: model.showsResults.peek(),
    loadingMore: model.loadingMore.peek(),
    pagingFailed: model.pagingFailed.peek(),
    hasOlder: model.hasOlder.peek(),
    indexComplete: model.indexComplete.peek(),
    canGoOlder: model.canGoOlder.peek(),
    canGoNewer: model.canGoNewer.peek(),
    fieldFocused: model.fieldFocused.peek(),
    focusInField: !!input && document.activeElement === input,
    activeElement: describe(document.activeElement),
    ariaExpanded: input?.getAttribute("aria-expanded") ?? null,
    ariaActiveDescendant: activeDescendant,
    activeOptionRendered: activeDescendant ? !!document.getElementById(activeDescendant) : false,
    renderedOptions: document.querySelectorAll('[data-find-bar] [role="option"]').length,
    resultsScrollTop: resultsList()?.scrollTop ?? null,
    commands: {
      find: lab.registry.isEnabled(findCommandIds.find),
      findNext: lab.registry.isEnabled(findCommandIds.findNext),
      findPrevious: lab.registry.isEnabled(findCommandIds.findPrevious),
    },
    jumps: lab.jumps.peek().slice(-20),
    jumpCount: lab.jumps.peek().length,
    highlighted: lab.highlight.peek()?.messageId ?? null,
    focusRestores: lab.focusRestores,
    chatScrollTop: lab.listElement()?.scrollTop ?? null,
    core: { ...lab.core.settings, ...lab.core.stats, pending: lab.core.pending() },
    renderCounts: counter.counts(),
    messages: lab.core.messages.length,
    platform: lab.platform,
    theme,
    dir,
  }
}

const dispatchKey = (target: EventTarget, name: string, modifiers: { meta?: boolean; ctrl?: boolean; alt?: boolean; shift?: boolean; composing?: boolean } = {}) => {
  const event = new KeyboardEvent("keydown", {
    key: name,
    code: name.length === 1 ? `Key${name.toUpperCase()}` : name,
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

const mod = () => (lab.platform.os === "mac" ? { meta: true } : { ctrl: true })

const control = {
  /** Open (or focus) the bar directly, optionally seeded. */
  open: (seed?: string) => lab.model.open(seed !== undefined ? { seed } : {}),
  close: () => lab.model.close(),
  /** Press a find shortcut where focus is (the real dispatcher path). Returns whether the app took the key. */
  shortcut: (name: "find" | "next" | "previous") => {
    const target = document.activeElement ?? document.body
    if (name === "find") return dispatchKey(target, "f", mod())
    return dispatchKey(target, "g", { ...mod(), shift: name === "previous" })
  },
  /** Replace the field's text as typing would (an input event). */
  type: (text: string) => {
    const input = field()
    if (!input) return false
    input.value = text
    input.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertText", data: text }))
    return true
  },
  /** An input method composition: nothing is searched until it ends. */
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
  /** A key in the field (Enter, Escape, ArrowUp, ...). Returns whether it was handled. */
  key: (name: string, modifiers: { meta?: boolean; ctrl?: boolean; alt?: boolean; shift?: boolean; composing?: boolean } = {}) =>
    dispatchKey(field() ?? document.body, name, modifiers),
  next: () => lab.model.next(),
  previous: () => lab.model.previous(),
  toggleResults: () => lab.model.toggleResults(),
  /** Click the preview at a loaded index (scrolls the results list to it first). */
  activate: (index: number) => {
    const hit = lab.model.hits.peek()[index]
    if (!hit) return false
    lab.model.activate(hit)
    return true
  },
  /** Scroll the results list to its end (pages load near the end). */
  scrollResultsToEnd: () => {
    const list = resultsList()
    if (!list) return false
    list.scrollTop = list.scrollHeight
    list.dispatchEvent(new Event("scroll"))
    return true
  },
  /** Select text in a message of the lab's list (for seeding Mod+F). */
  selectText: (messageId: string, start = 0, end?: number) => {
    const node = document.querySelector(`[data-message-id="${messageId}"] [data-text]`)?.firstChild
    if (!node) return false
    const range = document.createRange()
    range.setStart(node, Math.min(start, node.textContent?.length ?? 0))
    range.setEnd(node, Math.min(end ?? node.textContent?.length ?? 0, node.textContent?.length ?? 0))
    const selection = document.getSelection()
    selection?.removeAllRanges()
    selection?.addRange(range)
    return true
  },
  focusList: () => lab.listElement()?.focus({ preventScroll: true }),
  setDelay: (ms: number) => {
    lab.setDelay(ms)
    updateSettings()
  },
  setMode: (mode: LabCoreMode) => {
    if (!modes.includes(mode)) return false
    lab.setMode(mode)
    updateSettings()
    return true
  },
  /** Server matches: "off" (device holds everything), "older" (server adds older history), "fail" (offline). Applies to the next query; `retry()` re-asks. */
  setServer: (server: LabServerMode) => {
    if (!serverModes.includes(server)) return false
    lab.setServer(server)
    updateSettings()
    return true
  },
  retry: () => lab.model.retry(),
  setTheme: (next: Theme) => {
    applyTheme(next)
    updateSettings()
  },
  setDir: (next: Dir) => {
    applyDir(next)
    updateSettings()
  },
  resetRenderCounts: () => counter.reset(),
  /** Resolves with a snapshot once no request is waiting and the model is not searching (or after `timeoutMs`). */
  settle: (timeoutMs = 5000) =>
    new Promise<ReturnType<typeof snapshot>>((resolve) => {
      const started = performance.now()
      const check = () => {
        const busy =
          lab.core.pending() > 0 ||
          lab.model.state.peek() === "searching" ||
          lab.model.loadingMore.peek() ||
          lab.model.serverSearching.peek()
        if (!busy || performance.now() - started > timeoutMs) {
          requestAnimationFrame(() => resolve(snapshot()))
          return
        }
        setTimeout(check, 16)
      }
      setTimeout(check, 0)
    }),
  snapshot,
}

Object.defineProperty(globalThis, "__findLab", { configurable: true, get: snapshot })
Object.defineProperty(globalThis, "__findLabControl", { configurable: true, value: control })

// ---------------------------------------------------------------------------
// View

function Lab() {
  const shown = useSignal(settings)
  const findKeys = shortcutKeys(parseCombo("Mod+F", lab.platform.os), lab.platform.os)
  const nextKeys = shortcutKeys(parseCombo("Mod+G", lab.platform.os), lab.platform.os)
  return (
    <div {...stylex.props(styles.page)}>
      <header {...stylex.props(styles.header)}>
        <h1 {...stylex.props(styles.title)}>Find lab</h1>
        <button type="button" data-lab="open" onClick={() => lab.model.open()} {...stylex.props(styles.button)}>
          Find in Chat{" "}
          <span dir="ltr">
            <Kbd keys={findKeys} />
          </span>
        </button>
        <span {...stylex.props(styles.hint)}>
          Next <Kbd keys={nextKeys} />
        </span>
        <Segmented label="Appearance" value={shown.theme} options={["system", "light", "dark"]} onChange={control.setTheme} />
        <Segmented label="Direction" value={shown.dir} options={["ltr", "rtl"]} onChange={control.setDir} />
        <Segmented label="Core" value={shown.mode} options={modes} onChange={control.setMode} />
        <Segmented label="Server" value={shown.server} options={serverModes} onChange={control.setServer} />
        <label {...stylex.props(styles.label)}>
          Delay
          <input
            type="number"
            min={0}
            step={50}
            value={shown.delayMs}
            onChange={(event) => control.setDelay(Number(event.currentTarget.value))}
            {...stylex.props(styles.number)}
          />
          ms
        </label>
        <span {...stylex.props(styles.hint)}>{lab.core.messages.length.toLocaleString("en-US")} messages; try “deploy” (about 2,600 matches), “deploy bu”, “the”, “سلام”.</span>
      </header>
      <div {...stylex.props(styles.chat)}>
        <MessageList />
        <FindBar model={lab.model} platform={lab.platform} sender={lab.sender} />
      </div>
    </div>
  )
}

function MessageList() {
  countRender("lab:list")
  const ref = useElement(lab.listPart)
  return (
    <div ref={ref} tabIndex={0} role="log" aria-label="Messages" data-focus-region="timeline" data-lab="messages" {...stylex.props(styles.list)}>
      {lab.core.messages.map((message) => (
        <MessageRow key={message.messageId} message={message} />
      ))}
    </div>
  )
}

const MessageRow = memo(function MessageRow(props: { message: LabMessage }) {
  countRender("lab:row")
  const { message } = props
  const highlight = useSignal(lab.rowHighlight(message.messageId as MessageID))
  const segments = highlightSegments(message.text, highlight?.ranges ?? [])
  const sender = lab.sender(message.fromId, message.out)
  return (
    <div data-message-id={message.messageId} {...stylex.props(styles.row, highlight && styles.rowHighlighted)}>
      <span {...stylex.props(styles.rowMeta)}>
        <span dir="auto">{sender.name}</span> · #{message.messageId}
      </span>
      <span dir="auto" data-text="" {...stylex.props(styles.rowText)}>
        {segments.map((segment, index) =>
          segment.highlighted ? (
            <mark key={index} {...stylex.props(styles.mark)}>
              {segment.text}
            </mark>
          ) : (
            segment.text
          ),
        )}
      </span>
    </div>
  )
})

function Segmented<T extends string>(props: { label: string; value: T; options: readonly T[]; onChange: (value: T) => void }) {
  return (
    <span role="group" aria-label={props.label} {...stylex.props(styles.segmented)}>
      {props.options.map((option) => (
        <button
          key={option}
          type="button"
          aria-pressed={props.value === option}
          onClick={() => props.onChange(option)}
          {...stylex.props(styles.segment, props.value === option && styles.segmentOn)}
        >
          {option}
        </button>
      ))}
    </span>
  )
}

const styles = stylex.create({
  page: {
    boxSizing: "border-box",
    blockSize: "100vh",
    display: "flex",
    flexDirection: "column",
    backgroundColor: color.windowBackground,
    color: color.label,
    fontFamily: font.familySystem,
    fontSize: font.sizeBody,
  },
  header: {
    display: "flex",
    flexWrap: "wrap",
    alignItems: "center",
    gap: space.md,
    paddingBlock: space.md,
    paddingInline: space.xl,
    borderBlockEndWidth: "1px",
    borderBlockEndStyle: "solid",
    borderBlockEndColor: color.separator,
  },
  title: {
    margin: 0,
    fontSize: font.sizeTitle3,
    fontWeight: font.weightSemibold,
  },
  button: {
    display: "inline-flex",
    alignItems: "center",
    gap: space.sm,
    paddingBlock: space.xs,
    paddingInline: space.md,
    borderRadius: radius.control,
    borderWidth: "1px",
    borderStyle: "solid",
    borderColor: color.controlBorder,
    backgroundColor: color.control,
    color: color.controlText,
    fontFamily: font.familySystem,
    fontSize: font.sizeBody,
  },
  hint: {
    display: "inline-flex",
    alignItems: "center",
    gap: space.xs,
    color: color.secondaryLabel,
  },
  label: {
    display: "inline-flex",
    alignItems: "center",
    gap: space.xs,
    color: color.secondaryLabel,
  },
  number: {
    inlineSize: "72px",
    fontFamily: font.familySystem,
    fontSize: font.sizeBody,
  },
  segmented: {
    display: "inline-flex",
    borderRadius: radius.control,
    borderWidth: "1px",
    borderStyle: "solid",
    borderColor: color.controlBorder,
    overflow: "hidden",
  },
  segment: {
    borderStyle: "none",
    paddingBlock: space.xxs,
    paddingInline: space.md,
    backgroundColor: color.control,
    color: color.controlText,
    fontFamily: font.familySystem,
    fontSize: font.sizeCallout,
  },
  segmentOn: {
    backgroundColor: color.accent,
    color: color.onAccent,
  },
  chat: {
    position: "relative",
    flexGrow: 1,
    minBlockSize: 0,
  },
  list: {
    position: "relative",
    boxSizing: "border-box",
    blockSize: "100%",
    overflowY: "auto",
    overflowAnchor: "none",
    paddingBlock: space.xl,
    paddingInline: space.xl,
    outline: "none",
  },
  row: {
    display: "flex",
    flexDirection: "column",
    gap: space.xxs,
    paddingBlock: space.sm,
    paddingInline: space.md,
    borderRadius: radius.content,
    maxInlineSize: "720px",
  },
  rowHighlighted: {
    backgroundColor: color.controlPressed,
  },
  rowMeta: {
    fontSize: font.sizeCaption,
    color: color.secondaryLabel,
  },
  rowText: {
    whiteSpace: "pre-wrap",
    textAlign: "start",
  },
  mark: {
    backgroundColor: { default: "light-dark(rgb(255 204 0 / 0.45), rgb(255 214 10 / 0.35))", "@media (forced-colors: active)": "Mark" },
    color: { default: "inherit", "@media (forced-colors: active)": "MarkText" },
    borderRadius: radius.small,
  },
})

const root = document.getElementById("root")
if (root) {
  createRoot(root).render(<Lab />)
  if (params.get("open") === "1") {
    lab.model.open()
    const q = params.get("q")
    if (q) lab.model.setText(q)
  }
}
