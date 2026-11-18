/**
 * Quick Search (Cmd/Ctrl+K): a modal palette in the top layer, near the top
 * of the window as on the Mac (`QuickSearchPopover.swift`: 510 wide, 56 below
 * the window's top, rows of the sidebar's height, 11 px section headings).
 *
 * Mount it once in the signed-in shell with the session's wiring; it renders
 * nothing visible until the model opens. Rows are memoized and read only
 * whether they are active, so a keystroke renders only rows whose item
 * changed and moving the highlight renders two rows.
 */

import { useElement, useModel, useSignal } from "@inline/reactive/react"
import { countRender } from "@inline/reactive/react/testing"
import { Kbd, Progress } from "@inline/ui/react"
import { color } from "@inline/ui/tokens/color.stylex"
import { font } from "@inline/ui/tokens/font.stylex"
import { motion } from "@inline/ui/tokens/motion.stylex"
import { radius } from "@inline/ui/tokens/radius.stylex"
import { shadow } from "@inline/ui/tokens/shadow.stylex"
import { size } from "@inline/ui/tokens/size.stylex"
import { space } from "@inline/ui/tokens/space.stylex"
import type { AsyncSectionState, QuickSearchEmptyState, QuickSearchItem, QuickSearchSection } from "@inline/view/quick-search"
import * as stylex from "@stylexjs/stylex"
import { memo } from "react"
import { QuickSearchPaletteController, type RowVisual } from "./palette-controller"
import { sameItem, type TextSegment } from "./present"
import type { QuickSearchWiring } from "./wiring"

export type QuickSearchPaletteProps = {
  /** From `wireQuickSearch(session, options)`. */
  readonly quickSearch: QuickSearchWiring
  readonly placeholder?: string
}

export function QuickSearchPalette(props: QuickSearchPaletteProps) {
  countRender("quick-search:palette")
  const controller = useModel(() => new QuickSearchPaletteController({ quickSearch: props.quickSearch }), [props.quickSearch])
  const dialogRef = useElement(controller.dialog.content)
  const surfaceRef = useElement(controller.dialog.surface)
  const inputRef = useElement(controller.input)
  const open = useSignal(controller.model.isOpen)
  return (
    <dialog ref={dialogRef} {...stylex.props(styles.dialog)}>
      <div ref={surfaceRef} {...stylex.props(styles.surface)}>
        <div {...stylex.props(styles.header)}>
          <SearchIcon />
          <input
            ref={inputRef}
            type="text"
            dir="auto"
            aria-label="Search"
            placeholder={props.placeholder ?? "Search chats, members, and messages"}
            enterKeyHint="go"
            {...stylex.props(styles.input)}
          />
        </div>
        <div aria-hidden="true" {...stylex.props(styles.divider)} />
        {open ? <Results controller={controller} /> : <div {...stylex.props(styles.scroller)} />}
        <Footer mac={controller.quickSearch.platform.os === "mac"} />
      </div>
    </dialog>
  )
}

// ---------------------------------------------------------------------------
// Results

const Results = memo(function Results(props: { controller: QuickSearchPaletteController }) {
  countRender("quick-search:results")
  const { controller } = props
  const model = controller.model
  const sections = useSignal(model.sections)
  const empty = useSignal(model.emptyState)
  const messages = useSignal(model.messagesState)
  const global = useSignal(model.globalState)
  const scrollerRef = useElement(controller.scroller)
  const listRef = useElement(controller.list)
  return (
    <div ref={scrollerRef} {...stylex.props(styles.scroller)}>
      <div ref={listRef} {...stylex.props(styles.list)}>
        {sections.map((section) => (
          <Section key={section.kind} section={section} controller={controller} />
        ))}
      </div>
      <Status empty={empty} hasItems={sections.length > 0} messages={messages} global={global} />
    </div>
  )
})

const Section = memo(function Section(props: { section: QuickSearchSection; controller: QuickSearchPaletteController }) {
  countRender("quick-search:section")
  const { section, controller } = props
  const headingId = controller.sectionId(section.kind)
  return (
    <div role="presentation" {...stylex.props(styles.section)}>
      <div id={headingId} aria-hidden="true" {...stylex.props(styles.heading)}>
        {section.title}
      </div>
      <div role="group" aria-labelledby={headingId} {...stylex.props(styles.group)}>
        {section.items.map((item) => (
          <Row key={item.id} item={item} controller={controller} />
        ))}
      </div>
    </div>
  )
})

type RowProps = { item: QuickSearchItem; controller: QuickSearchPaletteController }

const Row = memo(
  function Row(props: RowProps) {
    countRender("quick-search:row")
    const { item, controller } = props
    const active = useSignal(controller.isActive(item.id))
    const presentation = controller.present(item)
    return (
      <div
        id={controller.optionId(item.id)}
        role="option"
        aria-selected={active}
        aria-label={presentation.label}
        data-quick-search-id={item.id}
        {...stylex.props(styles.row, active && styles.rowActive)}
      >
        <RowIcon visual={presentation.visual} />
        <span {...stylex.props(styles.text)}>
          <span
            dir="auto"
            data-quick-search-part="title"
            {...stylex.props(styles.title, item.kind === "message" && styles.messageTitle)}
          >
            <Segments segments={presentation.title} />
          </span>
          {presentation.secondary.length > 0 && (
            <span dir="auto" data-quick-search-part="secondary" {...stylex.props(styles.secondary)}>
              <Segments segments={presentation.secondary} />
            </span>
          )}
        </span>
        <span {...stylex.props(styles.trailing)}>
          {presentation.shortcut && (
            <span dir="ltr" {...stylex.props(styles.shortcut)}>
              <Kbd keys={presentation.shortcut} />
            </span>
          )}
          <span {...stylex.props(styles.kind)}>{presentation.trailing}</span>
        </span>
      </div>
    )
  },
  (previous, next) => previous.controller === next.controller && sameItem(previous.item, next.item),
)

/** Text split at the matcher's ranges, as text nodes; highlights are `<mark>`. */
function Segments(props: { segments: readonly TextSegment[] }) {
  return (
    <>
      {props.segments.map((segment, index) =>
        segment.highlighted ? (
          <mark key={index} {...stylex.props(styles.mark)}>
            {segment.text}
          </mark>
        ) : (
          segment.text
        ),
      )}
    </>
  )
}

function RowIcon(props: { visual: RowVisual }) {
  const visual = props.visual
  switch (visual.kind) {
    case "photo":
      return (
        <span aria-hidden="true" {...stylex.props(styles.icon)}>
          <span {...stylex.props(styles.avatar, styles.circle)}>
            <img src={visual.url} alt="" draggable={false} loading="lazy" decoding="async" {...stylex.props(styles.photo)} />
          </span>
        </span>
      )
    case "emoji":
      return (
        <span aria-hidden="true" {...stylex.props(styles.icon)}>
          <span {...stylex.props(styles.avatar, styles.circle, styles.emoji)}>{visual.emoji}</span>
        </span>
      )
    case "initials":
      return (
        <span aria-hidden="true" {...stylex.props(styles.icon)}>
          <span
            {...stylex.props(
              styles.avatar,
              visual.shape === "square" ? styles.square : styles.circle,
              styles.initials,
              dynamic.avatarColors(visual.colors.gradientTop, visual.colors.background, visual.colors.border),
            )}
          >
            {visual.initials}
          </span>
        </span>
      )
    case "command":
      return (
        <span aria-hidden="true" {...stylex.props(styles.icon)}>
          <span {...stylex.props(styles.avatar, styles.circle, styles.glyph)}>
            <CommandGlyph />
          </span>
        </span>
      )
    case "create":
      return (
        <span aria-hidden="true" {...stylex.props(styles.icon)}>
          <span {...stylex.props(styles.avatar, styles.circle, styles.glyph)}>
            <PlusGlyph />
          </span>
        </span>
      )
  }
}

// ---------------------------------------------------------------------------
// Empty, loading and error states

function Status(props: { empty: QuickSearchEmptyState; hasItems: boolean; messages: AsyncSectionState; global: AsyncSectionState }) {
  if (!props.hasItems) {
    if (props.empty === "loading") return <Searching />
    const text =
      props.empty === "error"
        ? "Failed to load"
        : props.empty === "noResults"
          ? "No results found"
          : "Type to search chats, people and commands"
    return (
      <div role="status" {...stylex.props(styles.statusRow)}>
        {text}
      </div>
    )
  }
  // Below everything shown, so it never moves a row that is already there.
  const pending = props.messages.status === "pending" || props.global.status === "pending"
  const errors: string[] = []
  if (props.messages.status === "error") errors.push("Messages failed to load")
  if (props.global.status === "error") errors.push("Global search failed to load")
  return (
    <>
      {errors.map((text) => (
        <div key={text} role="status" {...stylex.props(styles.statusRow)}>
          {text}
        </div>
      ))}
      {pending && <Searching />}
    </>
  )
}

function Searching() {
  return (
    <div {...stylex.props(styles.statusRow, styles.searching)}>
      <Progress variant="spinner" label="Searching" />
      <span>Searching…</span>
    </div>
  )
}

// ---------------------------------------------------------------------------
// Footer

function Footer(props: { mac: boolean }) {
  const mod = props.mac ? "⌘" : "Ctrl"
  const enter = props.mac ? "↩" : "Enter"
  return (
    <div aria-hidden="true" {...stylex.props(styles.footer)}>
      <Hint keys={[enter]} label="Open" />
      <Hint keys={[mod, enter]} label="Other pane" />
      <Hint keys={["↑", "↓"]} label="Move" />
      <Hint keys={[props.mac ? "⇥" : "Tab"]} label="Sections" />
      <Hint keys={[props.mac ? "esc" : "Esc"]} label="Close" />
    </div>
  )
}

function Hint(props: { keys: readonly string[]; label: string }) {
  return (
    <span {...stylex.props(styles.hint)}>
      <span dir="ltr">
        <Kbd keys={props.keys} />
      </span>
      {props.label}
    </span>
  )
}

// ---------------------------------------------------------------------------
// Glyphs

function SearchIcon() {
  return (
    <svg aria-hidden="true" width="16" height="16" viewBox="0 0 16 16" {...stylex.props(styles.searchIcon)}>
      <circle cx="7" cy="7" r="4.75" fill="none" stroke="currentColor" strokeWidth="1.5" />
      <path d="M10.5 10.5 14 14" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" />
    </svg>
  )
}

function CommandGlyph() {
  return (
    <svg width="14" height="14" viewBox="0 0 16 16" aria-hidden="true">
      <path
        d="M5.5 5.5h5v5h-5zM5.5 5.5V4a1.5 1.5 0 1 0-1.5 1.5h1.5Zm5 0V4a1.5 1.5 0 1 1 1.5 1.5h-1.5Zm0 5V12a1.5 1.5 0 1 0 1.5-1.5h-1.5Zm-5 0V12A1.5 1.5 0 1 1 4 10.5h1.5Z"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.3"
        strokeLinejoin="round"
      />
    </svg>
  )
}

function PlusGlyph() {
  return (
    <svg width="14" height="14" viewBox="0 0 16 16" aria-hidden="true">
      <path d="M8 3v10M3 8h10" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" />
    </svg>
  )
}

// ---------------------------------------------------------------------------
// Styles

const layerIn = stylex.keyframes({
  from: { opacity: 0, transform: "scale(0.98)" },
  to: { opacity: 1, transform: "scale(1)" },
})

const TOP_INSET = "min(56px, 8vh)"

const styles = stylex.create({
  dialog: {
    // Modal <dialog> is fixed and centered by the UA; pin it near the top instead.
    marginBlockStart: TOP_INSET,
    marginBlockEnd: "auto",
    marginInline: "auto",
    // `--quick-search-viewport-width` lets the lab try window widths; unset in the app.
    inlineSize: "min(510px, calc(var(--quick-search-viewport-width, 100vw) - 32px))",
    maxInlineSize: "none",
    maxHeight: "none",
    padding: 0,
    borderWidth: 0,
    backgroundColor: "transparent",
    color: color.label,
    overflow: "visible",
    outline: "none",
    fontFamily: font.familySystem,
    fontSize: font.sizeBody,
    lineHeight: font.lineHeightBody,
    "::backdrop": { backgroundColor: "transparent" },
  },
  surface: {
    display: "flex",
    flexDirection: "column",
    boxSizing: "border-box",
    height: `min(400px, calc(100vh - ${TOP_INSET} - 16px))`,
    minHeight: "160px",
    overflow: "hidden",
    backgroundColor: color.popoverBackground,
    backdropFilter: "blur(24px) saturate(1.6)",
    borderRadius: radius.dialog,
    boxShadow: shadow.dialog,
    borderWidth: { default: 0, "@media (prefers-contrast: more)": "1px", "@media (forced-colors: active)": "1px" },
    borderStyle: "solid",
    borderColor: { default: "transparent", "@media (prefers-contrast: more)": color.layerBorder, "@media (forced-colors: active)": "CanvasText" },
    animationName: layerIn,
    animationDuration: motion.durationFast,
    animationTimingFunction: motion.easeOut,
  },
  header: {
    display: "flex",
    alignItems: "center",
    gap: space.md,
    flexShrink: 0,
    height: "48px",
    paddingInline: space.xl,
    boxSizing: "border-box",
  },
  searchIcon: { flexShrink: 0, color: color.secondaryLabel },
  input: {
    flexGrow: 1,
    minWidth: 0,
    height: "36px",
    padding: 0,
    margin: 0,
    borderWidth: 0,
    backgroundColor: "transparent",
    color: color.label,
    fontFamily: "inherit",
    fontSize: font.sizeTitle3,
    fontWeight: font.weightMedium,
    outline: "none",
    "::placeholder": { color: color.secondaryLabel },
  },
  divider: {
    flexShrink: 0,
    height: "1px",
    backgroundColor: color.separator,
  },
  scroller: {
    flexGrow: 1,
    minHeight: 0,
    overflowY: "auto",
    overflowX: "hidden",
    overscrollBehavior: "contain",
    paddingBlock: "10px",
    paddingInline: "10px",
    boxSizing: "border-box",
    scrollbarWidth: "thin",
    scrollbarColor: `${color.tertiaryLabel} transparent`,
  },
  list: { display: "flex", flexDirection: "column", gap: space.md, outline: "none" },
  section: { display: "flex", flexDirection: "column" },
  heading: {
    display: "flex",
    alignItems: "center",
    height: "22px",
    paddingInline: space.xs,
    fontSize: font.sizeSubheadline,
    fontWeight: font.weightSemibold,
    color: color.secondaryLabel,
    userSelect: "none",
  },
  group: { display: "flex", flexDirection: "column", gap: "1px" },
  row: {
    display: "flex",
    alignItems: "center",
    gap: space.md,
    height: size.sidebarItem,
    flexShrink: 0,
    paddingInline: space.xs,
    boxSizing: "border-box",
    borderRadius: radius.sidebarItem,
    cursor: "default",
    userSelect: "none",
    outlineOffset: "-2px",
  },
  rowActive: {
    backgroundColor: color.controlPressed,
    outlineWidth: { default: 0, "@media (forced-colors: active)": "2px" },
    outlineStyle: "solid",
    outlineColor: { default: "transparent", "@media (forced-colors: active)": "Highlight" },
  },
  icon: {
    display: "inline-flex",
    alignItems: "center",
    justifyContent: "center",
    flexShrink: 0,
    width: "28px",
    height: "28px",
  },
  avatar: {
    display: "inline-flex",
    alignItems: "center",
    justifyContent: "center",
    width: "24px",
    height: "24px",
    overflow: "hidden",
    boxSizing: "border-box",
  },
  circle: { borderRadius: radius.pill },
  square: { borderRadius: radius.control },
  photo: { width: "100%", height: "100%", objectFit: "cover" },
  emoji: { fontSize: "15px", lineHeight: 1, backgroundColor: color.controlHover },
  initials: { color: "#ffffff", fontSize: font.sizeFootnote, fontWeight: font.weightSemibold, forcedColorAdjust: "none" },
  glyph: { color: color.secondaryLabel, backgroundColor: color.controlHover },
  text: {
    display: "flex",
    alignItems: "baseline",
    gap: "6px",
    flexGrow: 1,
    minWidth: 0,
    overflow: "hidden",
  },
  title: {
    flexShrink: 0,
    maxInlineSize: "100%",
    overflow: "hidden",
    textOverflow: "ellipsis",
    whiteSpace: "nowrap",
    color: color.label,
  },
  // A message hit's chat title keeps its own width up to a share of the
  // column and never shrinks below it; the snippet takes the rest. Shrinking
  // both by content width let a long snippet squeeze the title to a few
  // letters. Same numbers as `messageTitleMaxWidth` in present.ts.
  messageTitle: { flexShrink: 0, maxInlineSize: "clamp(min(7em, 50%), 40%, 16em)" },
  secondary: {
    flexGrow: 1,
    flexShrink: 1,
    minInlineSize: 0,
    overflow: "hidden",
    textOverflow: "ellipsis",
    whiteSpace: "nowrap",
    color: color.secondaryLabel,
  },
  mark: {
    backgroundColor: "transparent",
    color: "inherit",
    fontWeight: font.weightSemibold,
    textDecorationLine: { default: "none", "@media (forced-colors: active)": "underline" },
  },
  trailing: {
    display: "inline-flex",
    alignItems: "center",
    gap: space.md,
    flexShrink: 0,
    marginInlineStart: "auto",
    color: color.secondaryLabel,
    fontSize: font.sizeCallout,
    whiteSpace: "nowrap",
  },
  shortcut: { display: "inline-flex" },
  kind: { fontVariantNumeric: "tabular-nums" },
  statusRow: {
    display: "flex",
    alignItems: "center",
    gap: space.md,
    height: size.sidebarItem,
    paddingInline: space.xs,
    color: color.secondaryLabel,
    fontWeight: font.weightMedium,
    opacity: 0.8,
  },
  searching: { opacity: 0.9 },
  footer: {
    display: "flex",
    alignItems: "center",
    flexWrap: "wrap",
    columnGap: space.lg,
    rowGap: space.xxs,
    flexShrink: 0,
    minHeight: "30px",
    paddingInline: space.xl,
    paddingBlock: space.xs,
    boxSizing: "border-box",
    borderBlockStartWidth: "1px",
    borderBlockStartStyle: "solid",
    borderBlockStartColor: color.separator,
    color: color.secondaryLabel,
    fontSize: font.sizeSubheadline,
    userSelect: "none",
  },
  hint: { display: "inline-flex", alignItems: "center", gap: space.xs },
})

const dynamic = stylex.create({
  avatarColors: (top: string, bottom: string, border: string) => ({
    backgroundImage: `linear-gradient(to bottom, ${top}, ${bottom})`,
    boxShadow: `inset 0 0 0 0.5px ${border}`,
  }),
})
