/**
 * Emoji lab: the reaction picker (quick row and full picker, anchored at a
 * button or at the pointer), the composer's emoji button, the composer's `:`
 * suggestions over a plain field, an inline full picker for screenshots, and
 * a search table. Real engine, real usage store (in memory).
 *
 * Query parameters: `?theme=dark|light&dir=rtl&width=narrow&usage=empty&tone=medium&open=reaction|reactionFull|composer&q=<search>`.
 *
 * For automation: `globalThis.__emojiLab` is a snapshot of the state (read it
 * again after each step; `focusIn` says where focus is: in the reaction
 * picker, the composer picker, the inline quick row, or elsewhere on the
 * page); `globalThis.__emojiLabControl` drives it.
 */

import { signal } from "@inline/reactive"
import { useElement, useSignal } from "@inline/reactive/react"
import { color } from "@inline/ui/tokens/color.stylex"
import { font } from "@inline/ui/tokens/font.stylex"
import { radius } from "@inline/ui/tokens/radius.stylex"
import { space } from "@inline/ui/tokens/space.stylex"
import * as stylex from "@stylexjs/stylex"
import type { ReactNode } from "react"
import { createRoot } from "react-dom/client"
import { ComposerEmojiButton } from "../../features/emoji/ComposerEmojiButton"
import { emojiTokens } from "../../features/emoji/emoji.stylex"
import { EmojiPicker, EmojiPickerPlaceholder } from "../../features/emoji/EmojiPicker"
import type { EmojiPickerController } from "../../features/emoji/picker"
import { ReactionPickerPopover, ReactionPickerView } from "../../features/emoji/ReactionPicker"
import { isSkinTone, SKIN_TONES, type SkinTone } from "../../features/emoji/tone"
import { EmojiLab, LAB_MESSAGE } from "./lab-model"

if (import.meta.env.DEV) {
  void import("virtual:stylex:runtime")
}

type Theme = "system" | "light" | "dark"
type Dir = "ltr" | "rtl"
type Width = "normal" | "narrow"

const params = new URLSearchParams(location.search)
const settings = signal({
  theme: (["light", "dark"].includes(params.get("theme") ?? "") ? params.get("theme") : "system") as Theme,
  dir: (params.get("dir") === "rtl" ? "rtl" : "ltr") as Dir,
  width: (params.get("width") === "narrow" ? "narrow" : "normal") as Width,
})
const applySettings = () => {
  const { theme, dir } = settings.peek()
  document.documentElement.style.colorScheme = theme === "system" ? "light dark" : theme
  document.documentElement.dir = dir
}
applySettings()
const update = (patch: Partial<ReturnType<typeof settings.peek>>) => {
  settings.set({ ...settings.peek(), ...patch })
  applySettings()
}

const lab = new EmojiLab({ usage: params.get("usage") === "empty" ? "empty" : "seeded" })
const initialTone = params.get("tone")
if (isSkinTone(initialTone)) lab.services.usage.setSkinTone(initialTone)

// ---------------------------------------------------------------------------
// Views

function App() {
  const current = useSignal(settings)
  return (
    <div {...stylex.props(styles.page)}>
      <Controls />
      <div {...stylex.props(styles.columns, current.width === "narrow" && styles.narrow)}>
        <Section title="Reaction picker" note="Add Reaction anchors at the button; a click on the bubble anchors at the pointer.">
          <MessageBubble />
        </Section>
        <Section title="Quick row (inline)" note="The row a message opens with: its own emoji, learned picks, the default set; pressed = yours.">
          <div {...stylex.props(styles.surface)} data-lab="quick-static">
            <ReactionPickerView controller={lab.quickStatic} />
          </div>
        </Section>
        <Section title="Full picker (inline)" note="Search, tone, grid, preview, categories. Only visible rows are in the DOM.">
          <InlinePicker />
        </Section>
        <Section title="Composer" note="Type :wa, :+1, :x; the button opens the picker and inserts at the caret.">
          <Composer />
        </Section>
        <Section title="Search table" note="The engine's ranking (shared by the picker and the composer).">
          <SearchTable />
        </Section>
        <Section title="Log">
          <Log />
        </Section>
      </div>
      <ReactionPickerPopover controller={lab.reaction} />
    </div>
  )
}

function Section(props: { title: string; note?: string; children: ReactNode }) {
  return (
    <section {...stylex.props(styles.section)}>
      <h2 {...stylex.props(styles.heading)}>{props.title}</h2>
      {props.note ? <p {...stylex.props(styles.note)}>{props.note}</p> : null}
      {props.children}
    </section>
  )
}

function Controls() {
  const current = useSignal(settings)
  const tone = useSignal(lab.services.usage.skinTone)
  return (
    <div role="toolbar" aria-label="Lab settings" {...stylex.props(styles.controls)}>
      <label>
        Theme{" "}
        <select value={current.theme} onChange={(event) => update({ theme: event.currentTarget.value as Theme })}>
          <option value="system">System</option>
          <option value="light">Light</option>
          <option value="dark">Dark</option>
        </select>
      </label>
      <label>
        Direction{" "}
        <select value={current.dir} onChange={(event) => update({ dir: event.currentTarget.value as Dir })}>
          <option value="ltr">Left to right</option>
          <option value="rtl">Right to left</option>
        </select>
      </label>
      <label>
        Width{" "}
        <select value={current.width} onChange={(event) => update({ width: event.currentTarget.value as Width })}>
          <option value="normal">Normal</option>
          <option value="narrow">Narrow (240 px)</option>
        </select>
      </label>
      <label>
        Skin tone{" "}
        <select value={tone} onChange={(event) => lab.services.usage.setSkinTone(event.currentTarget.value as SkinTone)}>
          {SKIN_TONES.map((choice) => (
            <option key={choice} value={choice}>
              {choice}
            </option>
          ))}
        </select>
      </label>
      <button type="button" onClick={() => control.openReaction()}>
        Open reaction picker
      </button>
      <button
        type="button"
        onClick={() => {
          control.openReaction()
          control.expandReaction("")
        }}
      >
        Open full reaction picker
      </button>
      <button type="button" onClick={() => control.openComposerPicker()}>
        Open composer picker
      </button>
      <button type="button" onClick={() => lab.inline.peek()?.openToneMenu()}>
        Show tone choices
      </button>
      <button type="button" onClick={() => control.setQuery("inline", "zzqx")}>
        Show no results
      </button>
      <button type="button" onClick={() => lab.resetUsage("empty")}>
        Clear usage
      </button>
      <button type="button" onClick={() => lab.resetUsage("seeded")}>
        Seed usage
      </button>
    </div>
  )
}

function MessageBubble() {
  const mine = useSignal(lab.mine)
  return (
    <div {...stylex.props(styles.message)}>
      <div
        data-lab="message"
        {...stylex.props(styles.bubble)}
        onClick={(event) => lab.openReaction({ x: event.clientX, y: event.clientY, width: 0, height: 0 })}
      >
        {LAB_MESSAGE}
        <div {...stylex.props(styles.chips)}>
          {[...mine].map((emoji) => (
            <span key={emoji} {...stylex.props(styles.chip, styles.emoji)}>
              {emoji} 1
            </span>
          ))}
        </div>
      </div>
      <button type="button" data-lab="add-reaction" onClick={(event) => lab.openReaction(event.currentTarget)} {...stylex.props(styles.action)}>
        Add Reaction
      </button>
    </div>
  )
}

function InlinePicker() {
  const picker = useSignal(lab.inline)
  return (
    <div data-lab="inline-picker" {...stylex.props(styles.surface, styles.pickerFrame)}>
      {picker ? <EmojiPicker controller={picker} /> : <EmojiPickerPlaceholder />}
    </div>
  )
}

const composerField = {
  attach: (element: HTMLInputElement) => {
    const sync = () => lab.setComposer(element.value, element.selectionStart ?? element.value.length)
    const onKeyDown = (event: KeyboardEvent) => {
      if (lab.suggestions.peek().length === 0) return
      if (event.key === "Enter" || event.key === "Tab") {
        event.preventDefault()
        lab.acceptSuggestion(composerActive.peek())
        composerActive.set(0)
      } else if (event.key === "ArrowDown" || event.key === "ArrowUp") {
        event.preventDefault()
        const count = lab.suggestions.peek().length
        composerActive.set((composerActive.peek() + (event.key === "ArrowDown" ? 1 : count - 1)) % count)
      }
    }
    element.addEventListener("input", sync)
    element.addEventListener("keyup", sync)
    element.addEventListener("click", sync)
    element.addEventListener("keydown", onKeyDown)
    return () => {
      element.removeEventListener("input", sync)
      element.removeEventListener("keyup", sync)
      element.removeEventListener("click", sync)
      element.removeEventListener("keydown", onKeyDown)
    }
  },
}
const composerActive = signal(0)

function Composer() {
  const text = useSignal(lab.composerText)
  const rows = useSignal(lab.suggestions)
  const active = useSignal(composerActive)
  const ref = useElement(composerField)
  return (
    <div {...stylex.props(styles.composer)}>
      {rows.length > 0 ? (
        <ul role="listbox" aria-label="Emoji" data-lab="suggestions" {...stylex.props(styles.suggestions)}>
          {rows.map((row, index) => (
            <li key={row.id} role="option" aria-selected={index === active} {...stylex.props(styles.suggestion, index === active && styles.suggestionActive)}>
              <span {...stylex.props(styles.emoji)}>{row.glyph}</span>
              <span>{row.title}</span>
              <span {...stylex.props(styles.note)}>{row.subtitle}</span>
            </li>
          ))}
        </ul>
      ) : null}
      <div {...stylex.props(styles.composerRow)}>
        <input ref={ref} data-lab="composer" value={text} onChange={() => undefined} placeholder="Message" aria-label="Message" {...stylex.props(styles.field)} />
        <ComposerEmojiButton controller={lab.composer} />
      </div>
    </div>
  )
}

const searchQuery = signal(params.get("q") ?? "heart")

function SearchTable() {
  const query = useSignal(searchQuery)
  const engine = useSignal(lab.engine)
  const results = engine ? engine.search(query, { limit: 12, usage: lab.services.usage.scores() }) : []
  return (
    <div>
      <input value={query} aria-label="Search query" onChange={(event) => searchQuery.set(event.currentTarget.value)} {...stylex.props(styles.field)} />
      <ol data-lab="search-results" {...stylex.props(styles.results)}>
        {results.map((info) => (
          <li key={info.index}>
            <span {...stylex.props(styles.emoji)}>{info.emoji}</span> :{info.shortcode}: <span {...stylex.props(styles.note)}>{info.label}</span>
          </li>
        ))}
      </ol>
    </div>
  )
}

function Log() {
  const lines = useSignal(lab.log)
  return (
    <ol data-lab="log" {...stylex.props(styles.results)}>
      {lines.map((line, index) => (
        <li key={`${index}:${line}`}>{line}</li>
      ))}
    </ol>
  )
}

// ---------------------------------------------------------------------------
// Automation

const describe = (element: Element | null) =>
  element
    ? `${element.tagName.toLowerCase()}${element.id ? `#${element.id}` : ""}${element.getAttribute("aria-label") ? `[${element.getAttribute("aria-label")}]` : ""}`
    : null

const pickerState = (name: string, picker: EmojiPickerController | undefined, root: Element | null) => {
  if (!picker) return { name, ready: false }
  const highlight = picker.highlight.peek()
  const item = highlight ? picker.itemAt(highlight) : undefined
  const grid = root?.querySelector('[role="grid"]')
  return {
    name,
    ready: true,
    query: picker.query.peek(),
    sections: picker.sections.peek().map((section) => `${section.id}:${section.items.length}`),
    activeCell: highlight && item ? { ...highlight, emoji: item.emoji, label: item.info.label, shortcode: item.info.shortcode, id: picker.cellId(highlight) } : null,
    activeCellRendered: highlight ? !!document.getElementById(picker.cellId(highlight)) : false,
    activeTab: picker.activeTab.peek(),
    columns: picker.columns.peek(),
    totalRows: picker.layout.peek().rows.length,
    model: picker.renderedCounts(),
    renderedRows: grid?.querySelectorAll('[role="row"]').length ?? 0,
    renderedCells: grid?.querySelectorAll('[role="gridcell"][data-item]').length ?? 0,
    scrollTop: grid?.scrollTop ?? 0,
    toneMenuOpen: picker.toneMenuOpen.peek(),
    preview: picker.preview.peek()?.info.shortcode ?? null,
  }
}

const reactionRoot = () => document.getElementById(lab.reaction.popover.id)

/** Where focus is, for a coordinator that cannot take screenshots. */
const focusIn = (): "reaction" | "composer" | "inline" | "page" => {
  const active = document.activeElement
  if (!active || active === document.body) return "page"
  if (reactionRoot()?.contains(active)) return "reaction"
  if (document.getElementById(lab.composer.popover.id)?.contains(active)) return "composer"
  if (document.querySelector('[data-lab="quick-static"]')?.contains(active)) return "inline"
  return "page"
}

const snapshot = () => ({
  ready: !!lab.engine.peek(),
  settings: settings.peek(),
  skinTone: lab.services.usage.skinTone.peek(),
  support: lab.services.support.stats(),
  open: {
    reaction: lab.reaction.popover.isOpen.peek(),
    reactionMode: lab.reaction.mode.peek(),
    composer: lab.composer.popover.isOpen.peek(),
  },
  reaction: {
    quick: lab.reaction.quick.peek().map((item) => (item.mine ? `${item.emoji}*` : item.emoji)),
    focusIndex: lab.reaction.focusIndex.peek(),
    loading: lab.reaction.loading.peek(),
  },
  mine: [...lab.mine.peek()],
  pickers: [
    pickerState("inline", lab.inline.peek(), document.querySelector('[data-lab="inline-picker"]')),
    pickerState("reaction", lab.reaction.full.peek(), reactionRoot()),
    pickerState("composer", lab.composer.picker.peek(), document.getElementById(lab.composer.popover.id)),
  ],
  composer: {
    text: lab.composerText.peek(),
    trigger: lab.trigger.peek(),
    suggestions: lab.suggestions.peek().map((row) => `${row.emoji} ${row.title}`),
  },
  search: { query: searchQuery.peek(), results: lab.engine.peek()?.search(searchQuery.peek(), { limit: 12 }).map((info) => `${info.emoji} ${info.shortcode}`) ?? [] },
  log: lab.log.peek(),
  activeElement: describe(document.activeElement),
  focusIn: focusIn(),
})

const pickerByName = (name: "inline" | "reaction" | "composer") =>
  name === "inline" ? lab.inline.peek() : name === "reaction" ? lab.reaction.full.peek() : lab.composer.picker.peek()

const control = {
  setTheme: (theme: Theme) => update({ theme }),
  setDir: (dir: Dir) => update({ dir }),
  setWidth: (width: Width) => update({ width }),
  setTone: (tone: SkinTone) => lab.services.usage.setSkinTone(tone),
  resetUsage: (mode: "seeded" | "empty" = "empty") => lab.resetUsage(mode),
  /** Open the reaction picker at the Add Reaction button (or at a point). The button is looked up when the picker opens. */
  openReaction: (point?: { x: number; y: number }) =>
    lab.openReaction(point ? { ...point, width: 0, height: 0 } : () => document.querySelector('[data-lab="add-reaction"]')),
  expandReaction: (query = "") => lab.reaction.expand(query),
  openComposerPicker: () => lab.composer.open(),
  closeAll: () => {
    lab.reaction.close()
    lab.composer.popover.close()
  },
  /** A key where focus is (the real listeners). Returns whether something used it. */
  key: (name: string, modifiers: { ctrl?: boolean; meta?: boolean; shift?: boolean; alt?: boolean } = {}) => {
    const target = document.activeElement ?? document.body
    const event = new KeyboardEvent("keydown", {
      key: name,
      bubbles: true,
      cancelable: true,
      ctrlKey: !!modifiers.ctrl,
      metaKey: !!modifiers.meta,
      shiftKey: !!modifiers.shift,
      altKey: !!modifiers.alt,
    })
    target.dispatchEvent(event)
    return event.defaultPrevented
  },
  /** Set a picker's search (as typing would). */
  setQuery: (name: "inline" | "reaction" | "composer", query: string) => pickerByName(name)?.setQuery(query),
  /** A key straight to a picker's model, from its search field or grid. */
  pickerKey: (name: "inline" | "reaction" | "composer", key: string, from: "search" | "grid" = "grid") =>
    pickerByName(name)?.handleKey({ key }, from) ?? false,
  focusInlineGrid: () => document.querySelector<HTMLElement>('[data-lab="inline-picker"] [role="grid"]')?.focus(),
  scrollInline: (top: number) => {
    const grid = document.querySelector<HTMLElement>('[data-lab="inline-picker"] [role="grid"]')
    if (!grid) return false
    grid.scrollTop = top
    grid.dispatchEvent(new Event("scroll"))
    return true
  },
  selectTab: (name: "inline" | "reaction" | "composer", index: number) => pickerByName(name)?.selectTab(index),
  /** The engine's results for a query, as `emoji shortcode`. */
  search: (query: string, limit = 12) => {
    searchQuery.set(query)
    return lab.engine.peek()?.search(query, { limit, usage: lab.services.usage.scores() }).map((info) => `${info.emoji} ${info.shortcode}`) ?? []
  },
  /** Type into the composer field (caret at the end) and read its suggestions. */
  typeComposer: (text: string) => {
    lab.setComposer(text)
    return lab.suggestions.peek().map((row) => `${row.emoji} ${row.title}`)
  },
  acceptSuggestion: (index = 0) => lab.acceptSuggestion(index),
}

Object.defineProperty(globalThis, "__emojiLab", { get: snapshot, configurable: true })
;(globalThis as { __emojiLabControl?: typeof control }).__emojiLabControl = control

const root = document.getElementById("root")
if (root) createRoot(root).render(<App />)

const open = params.get("open")
if (open === "reaction" || open === "reactionFull") {
  queueMicrotask(() => {
    control.openReaction()
    if (open === "reactionFull") control.expandReaction(params.get("q") ?? "")
  })
} else if (open === "composer") {
  queueMicrotask(() => control.openComposerPicker())
}

// ---------------------------------------------------------------------------

const styles = stylex.create({
  page: {
    minBlockSize: "100vh",
    padding: space.xl,
    boxSizing: "border-box",
    backgroundColor: color.windowBackground,
    color: color.label,
    fontFamily: font.familySystem,
    fontSize: font.sizeBody,
  },
  controls: {
    display: "flex",
    flexWrap: "wrap",
    gap: space.lg,
    alignItems: "center",
    marginBlockEnd: space.xl,
  },
  columns: {
    display: "grid",
    gridTemplateColumns: "repeat(auto-fill, minmax(340px, 1fr))",
    gap: space.xl,
    alignItems: "start",
  },
  narrow: {
    gridTemplateColumns: "240px",
  },
  section: {
    display: "flex",
    flexDirection: "column",
    gap: space.sm,
    minInlineSize: 0,
  },
  heading: {
    margin: 0,
    fontSize: font.sizeHeadline,
    fontWeight: font.weightSemibold,
  },
  note: {
    margin: 0,
    color: color.secondaryLabel,
    fontSize: font.sizeFootnote,
  },
  surface: {
    backgroundColor: color.popoverBackground,
    borderRadius: radius.popover,
    borderWidth: space.hairline,
    borderStyle: "solid",
    borderColor: color.layerBorder,
    overflow: "hidden",
    maxInlineSize: "100%",
    inlineSize: "fit-content",
  },
  pickerFrame: {
    inlineSize: "min(320px, 100%)",
  },
  message: {
    display: "flex",
    flexDirection: "column",
    alignItems: "flex-start",
    gap: space.sm,
  },
  bubble: {
    maxInlineSize: "100%",
    padding: space.md,
    borderRadius: radius.bubble,
    backgroundColor: color.secondaryBubble,
    color: color.secondaryBubbleText,
    cursor: "pointer",
  },
  chips: {
    display: "flex",
    gap: space.xs,
    marginBlockStart: space.xs,
  },
  chip: {
    paddingInline: space.sm,
    borderRadius: radius.pill,
    backgroundColor: color.controlHover,
  },
  emoji: {
    fontFamily: emojiTokens.fontFamily,
    fontVariantEmoji: "emoji",
  },
  action: {
    fontFamily: font.familySystem,
  },
  composer: {
    position: "relative",
    display: "flex",
    flexDirection: "column",
    gap: space.xs,
  },
  composerRow: {
    display: "flex",
    alignItems: "center",
    gap: space.xs,
  },
  field: {
    flexGrow: 1,
    minInlineSize: 0,
    padding: space.sm,
    borderWidth: space.hairline,
    borderStyle: "solid",
    borderColor: color.controlBorder,
    borderRadius: radius.control,
    backgroundColor: color.textBackground,
    color: color.label,
    fontFamily: font.familySystem,
    fontSize: font.sizeBody,
  },
  suggestions: {
    listStyle: "none",
    margin: 0,
    padding: space.xs,
    borderRadius: radius.menu,
    backgroundColor: color.menuBackground,
    borderWidth: space.hairline,
    borderStyle: "solid",
    borderColor: color.layerBorder,
  },
  suggestion: {
    display: "flex",
    gap: space.sm,
    alignItems: "center",
    paddingInline: space.sm,
    blockSize: "28px",
    borderRadius: radius.menuItem,
  },
  suggestionActive: {
    backgroundColor: color.selectedMenuItem,
    color: color.selectedMenuItemText,
  },
  results: {
    margin: 0,
    paddingInlineStart: space.xl,
  },
})
