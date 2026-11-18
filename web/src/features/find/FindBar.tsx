/**
 * Find in chat: the bar over the top of a chat pane, as on the Mac
 * (`InChatSearchBar.swift`): a 36 px capsule with the field, the count
 * ("3 of 128"), next and previous, a toggle between the previews and the
 * chat, and close; under it, the previews of every match (sender, time and
 * a snippet with the matched ranges highlighted), newest first.
 *
 * It overlays the message list (absolutely positioned in the pane's
 * message area, which must be `position: relative`) and never changes the
 * timeline's insets, so opening and closing it move nothing in the chat.
 *
 * Render it inside the chat pane's message area; it renders nothing while
 * the model is closed. Rows are memoized and read only whether they are
 * current, so moving through matches renders two rows.
 */

import type { MessageID } from "@inline/ids"
import { useElement, useModel, useSignal } from "@inline/reactive/react"
import { countRender } from "@inline/reactive/react/testing"
import { Avatar, Button, IconButton, Progress } from "@inline/ui/react"
import { color } from "@inline/ui/tokens/color.stylex"
import { font } from "@inline/ui/tokens/font.stylex"
import { layer } from "@inline/ui/tokens/layer.stylex"
import { motion } from "@inline/ui/tokens/motion.stylex"
import { radius } from "@inline/ui/tokens/radius.stylex"
import { shadow } from "@inline/ui/tokens/shadow.stylex"
import { size } from "@inline/ui/tokens/size.stylex"
import { space } from "@inline/ui/tokens/space.stylex"
import type { Platform } from "@inline/view"
import * as stylex from "@stylexjs/stylex"
import { memo, type ReactNode } from "react"
import { findShortcuts } from "./commands"
import { FindBarController, type FindBarControllerOptions } from "./find-bar-controller"
import type { FindHit, FindInChatModel } from "./find-model"
import { ariaShortcut, listHeight, shortcutHint } from "./present"

export type FindBarProps = {
  /** The chat pane's `FindInChatModel`. */
  readonly model: FindInChatModel
  readonly platform: Platform
  /** The sender of a match, for its preview (see `FindBarControllerOptions.sender`). */
  readonly sender?: FindBarControllerOptions["sender"]
  /** Wall clock in milliseconds. */
  readonly now?: () => number
  readonly placeholder?: string
}

export function FindBar(props: FindBarProps) {
  countRender("find:bar")
  const open = useSignal(props.model.isOpen)
  if (!open) return null
  return <OpenFindBar {...props} />
}

function OpenFindBar(props: FindBarProps) {
  const { model, platform } = props
  const controller = useModel(
    () =>
      new FindBarController({
        model,
        platform,
        ...(props.sender ? { sender: props.sender } : {}),
        ...(props.now ? { now: props.now } : {}),
      }),
    [model],
  )
  const showsResults = useSignal(model.showsResults)
  const state = useSignal(model.state)
  return (
    <div {...stylex.props(styles.overlay)} data-find-bar="">
      <div role="search" aria-label="Find in chat" onKeyDown={(event) => controller.barKeyDown(event)} {...stylex.props(styles.bar)}>
        <Field controller={controller} placeholder={props.placeholder ?? "Search in Chat"} />
        {showsResults && state !== "idle" ? <Panel controller={controller} /> : null}
      </div>
    </div>
  )
}

// ---------------------------------------------------------------------------
// The field row

function Field(props: { controller: FindBarController; placeholder: string }) {
  countRender("find:field")
  const { controller } = props
  const model = controller.model
  const inputRef = useElement(controller.input)
  const state = useSignal(model.state)
  const counter = useSignal(model.counterText)
  const canGoOlder = useSignal(model.canGoOlder)
  const canGoNewer = useSignal(model.canGoNewer)
  const showsResults = useSignal(model.showsResults)
  const query = useSignal(model.query)
  const nextHint = shortcutHint(findShortcuts.findNext, controller.platform)
  const previousHint = shortcutHint(findShortcuts.findPrevious, controller.platform)
  return (
    <div {...stylex.props(styles.field)}>
      <SearchGlyph />
      <input
        ref={inputRef}
        type="text"
        dir="auto"
        aria-label="Search in chat"
        placeholder={props.placeholder}
        enterKeyHint="search"
        {...stylex.props(styles.input)}
      />
      {state === "searching" ? <Progress variant="spinner" label="Searching" /> : null}
      <span role="status" aria-live="polite" {...stylex.props(styles.counter)}>
        {counter ?? ""}
      </span>
      <span {...stylex.props(styles.buttons)}>
        <IconButton
          size="small"
          label={nextHint ? `Next Match (${nextHint})` : "Next Match"}
          aria-keyshortcuts={ariaShortcut(findShortcuts.findNext, controller.platform)}
          icon={<ChevronUpGlyph />}
          disabled={!canGoOlder}
          onPointerDown={keepFocus}
          onClick={() => model.next()}
        />
        <IconButton
          size="small"
          label={previousHint ? `Previous Match (${previousHint})` : "Previous Match"}
          aria-keyshortcuts={ariaShortcut(findShortcuts.findPrevious, controller.platform)}
          icon={<ChevronDownGlyph />}
          disabled={!canGoNewer}
          onPointerDown={keepFocus}
          onClick={() => model.previous()}
        />
        <IconButton
          size="small"
          label={showsResults ? "Show in Chat" : "Show as List"}
          icon={showsResults ? <BubbleGlyph /> : <ListGlyph />}
          disabled={query.length === 0}
          onPointerDown={keepFocus}
          onClick={() => model.toggleResults()}
        />
        <IconButton size="small" label="Close Search (Esc)" icon={<CloseGlyph />} onClick={() => model.close()} />
      </span>
    </div>
  )
}

/** Pressing a bar button keeps focus in the field, as on the Mac. */
const keepFocus = (event: { preventDefault(): void; button: number }) => {
  if (event.button === 0) event.preventDefault()
}

// ---------------------------------------------------------------------------
// The previews panel

function Panel(props: { controller: FindBarController }) {
  countRender("find:panel")
  const { controller } = props
  const model = controller.model
  const hits = useSignal(model.hits)
  const state = useSignal(model.state)
  const stale = useSignal(model.stale)
  const loadingMore = useSignal(model.loadingMore)
  const pagingFailed = useSignal(model.pagingFailed)
  const indexComplete = useSignal(model.indexComplete)
  if (hits.length === 0) {
    return (
      <div {...stylex.props(styles.panel, styles.panelEmpty)}>
        <EmptyState state={state} onRetry={() => model.retry()} />
      </div>
    )
  }
  const footer = loadingMore || pagingFailed || !indexComplete
  return (
    <div {...stylex.props(styles.panel)}>
      <Rows controller={controller} hits={hits} stale={stale} height={listHeight(hits.length, footer)} />
      {footer ? (
        <div {...stylex.props(styles.footer)}>
          {loadingMore ? (
            <>
              <Progress variant="spinner" label="Searching older messages" />
              <span>Searching older messages…</span>
            </>
          ) : pagingFailed ? (
            <>
              <span>Couldn’t load older matches.</span>
              <Button size="small" variant="plain" onPointerDown={keepFocus} onClick={() => model.retry()}>
                Retry
              </Button>
            </>
          ) : (
            <span>Still indexing messages on this device; older matches may be missing.</span>
          )}
        </div>
      ) : null}
    </div>
  )
}

function EmptyState(props: { state: string; onRetry: () => void }) {
  switch (props.state) {
    case "searching":
      return <Progress variant="spinner" label="Searching" />
    case "error":
      return (
        <>
          <span>Couldn’t search messages.</span>
          <Button size="small" variant="plain" onPointerDown={keepFocus} onClick={props.onRetry}>
            Retry
          </Button>
        </>
      )
    case "indexIncomplete":
      return <span>No messages found yet. Still indexing messages on this device…</span>
    default:
      return <span>No messages found</span>
  }
}

const Rows = memo(function Rows(props: { controller: FindBarController; hits: readonly FindHit[]; stale: boolean; height: number }) {
  countRender("find:rows")
  const { controller, hits } = props
  const listRef = useElement(controller.list)
  const range = useSignal(controller.window)
  const hasOlder = useSignal(controller.model.hasOlder)
  const rows: ReactNode[] = []
  for (let index = range.start; index < range.end; index++) {
    const hit = hits[index]
    if (!hit) continue
    rows.push(
      <Row
        key={hit.messageId}
        controller={controller}
        hit={hit}
        index={index}
        setSize={hasOlder ? -1 : hits.length}
      />,
    )
  }
  return (
    <div ref={listRef} {...stylex.props(styles.list, dynamic.listHeight(props.height), props.stale && styles.stale)}>
      <div aria-hidden="true" {...stylex.props(dynamic.spacer(range.before))} />
      {rows}
      <div aria-hidden="true" {...stylex.props(dynamic.spacer(range.after))} />
    </div>
  )
})

const Row = memo(function Row(props: { controller: FindBarController; hit: FindHit; index: number; setSize: number }) {
  countRender("find:row")
  const { controller, hit } = props
  const active = useSignal(controller.isActive(hit.messageId as MessageID))
  const presentation = controller.present(hit)
  return (
    <div
      id={controller.optionId(hit.messageId)}
      role="option"
      aria-selected={active}
      aria-posinset={props.index + 1}
      aria-setsize={props.setSize}
      onPointerDown={(event) => controller.rowPointerDown(event)}
      onClick={() => controller.rowClick(hit)}
      {...stylex.props(styles.row, active && styles.rowActive)}
    >
      <span aria-hidden="true" {...stylex.props(styles.avatar)}>
        <Avatar
          name={presentation.sender.name}
          {...(presentation.sender.seed !== undefined ? { seed: presentation.sender.seed } : {})}
          {...(presentation.sender.photoUrl !== undefined ? { src: presentation.sender.photoUrl } : {})}
        />
      </span>
      <span {...stylex.props(styles.rowText)}>
        <span {...stylex.props(styles.rowHeader)}>
          <span dir="auto" {...stylex.props(styles.sender)}>
            {presentation.sender.name}
          </span>
          <span {...stylex.props(styles.date)}>{presentation.date}</span>
        </span>
        <span dir="auto" {...stylex.props(styles.snippet)}>
          {presentation.snippet.map((run, index) =>
            run.highlighted ? (
              <mark key={index} {...stylex.props(styles.mark)}>
                {run.text}
              </mark>
            ) : (
              <span key={index}>{run.text}</span>
            ),
          )}
        </span>
      </span>
    </div>
  )
})

// ---------------------------------------------------------------------------
// Glyphs (SF Symbols' magnifyingglass, chevron.up, chevron.down, list.bullet, bubble.left, xmark)

const Glyph = (props: { children: ReactNode }) => (
  <svg width={16} height={16} viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth={1.6} strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" focusable="false">
    {props.children}
  </svg>
)
const SearchGlyph = () => (
  <span {...stylex.props(styles.searchGlyph)}>
    <Glyph>
      <circle cx="7" cy="7" r="4.25" />
      <path d="M10.2 10.2L13.5 13.5" />
    </Glyph>
  </span>
)
const ChevronUpGlyph = () => (
  <Glyph>
    <path d="M3.5 10l4.5-4.5 4.5 4.5" />
  </Glyph>
)
const ChevronDownGlyph = () => (
  <Glyph>
    <path d="M3.5 6l4.5 4.5 4.5-4.5" />
  </Glyph>
)
const ListGlyph = () => (
  <Glyph>
    <path d="M6 4.5h7M6 8h7M6 11.5h7" />
    <circle cx="3" cy="4.5" r="0.6" fill="currentColor" />
    <circle cx="3" cy="8" r="0.6" fill="currentColor" />
    <circle cx="3" cy="11.5" r="0.6" fill="currentColor" />
  </Glyph>
)
const BubbleGlyph = () => (
  <Glyph>
    <path d="M3 4.5a2 2 0 0 1 2-2h6a2 2 0 0 1 2 2v4a2 2 0 0 1-2 2H7l-3 2.5v-2.6A2 2 0 0 1 3 8.5z" />
  </Glyph>
)
const CloseGlyph = () => (
  <Glyph>
    <path d="M4.5 4.5l7 7M11.5 4.5l-7 7" />
  </Glyph>
)

// ---------------------------------------------------------------------------
// Styles

const appear = stylex.keyframes({
  from: { opacity: 0 },
  to: { opacity: 1 },
})

const FIELD_HEIGHT = "36px"
// StyleX evaluates styles at build time from this file alone: these repeat `findListMetrics` (present.ts).
const LIST_INSET = "6px"
const ROW_HEIGHT = "54px"
const FOOTER_HEIGHT = "30px"

const styles = stylex.create({
  overlay: {
    position: "absolute",
    insetBlockStart: space.md,
    insetInline: space.lg,
    zIndex: layer.sticky,
    display: "flex",
    justifyContent: "center",
    pointerEvents: "none",
  },
  bar: {
    pointerEvents: "auto",
    inlineSize: "100%",
    maxInlineSize: "560px",
    display: "flex",
    flexDirection: "column",
    gap: space.sm,
    fontFamily: font.familySystem,
    fontSize: font.sizeBody,
    color: color.label,
  },
  field: {
    boxSizing: "border-box",
    blockSize: FIELD_HEIGHT,
    display: "flex",
    alignItems: "center",
    gap: space.md,
    paddingInlineStart: space.lg,
    paddingInlineEnd: space.md,
    borderRadius: radius.pill,
    backgroundColor: color.popoverBackground,
    boxShadow: shadow.menu,
    borderWidth: { default: 0, "@media (prefers-contrast: more)": "1px", "@media (forced-colors: active)": "1px" },
    borderStyle: "solid",
    borderColor: { default: "transparent", "@media (prefers-contrast: more)": color.layerBorder, "@media (forced-colors: active)": "CanvasText" },
  },
  searchGlyph: {
    display: "inline-flex",
    flexShrink: 0,
    color: color.secondaryLabel,
  },
  input: {
    flexGrow: 1,
    flexShrink: 1,
    minInlineSize: 0,
    blockSize: "100%",
    borderStyle: "none",
    outline: "none",
    backgroundColor: "transparent",
    color: color.label,
    fontFamily: font.familySystem,
    fontSize: font.sizeBody,
    paddingBlock: 0,
    paddingInline: 0,
    "::placeholder": { color: color.placeholderText },
  },
  counter: {
    flexShrink: 0,
    whiteSpace: "nowrap",
    color: color.secondaryLabel,
    fontSize: font.sizeCallout,
    fontVariantNumeric: "tabular-nums",
  },
  buttons: {
    display: "inline-flex",
    alignItems: "center",
    flexShrink: 0,
  },
  panel: {
    boxSizing: "border-box",
    borderRadius: radius.dialog,
    backgroundColor: color.popoverBackground,
    boxShadow: shadow.popover,
    overflow: "hidden",
    borderWidth: { default: 0, "@media (prefers-contrast: more)": "1px", "@media (forced-colors: active)": "1px" },
    borderStyle: "solid",
    borderColor: { default: "transparent", "@media (prefers-contrast: more)": color.layerBorder, "@media (forced-colors: active)": "CanvasText" },
    animationName: appear,
    animationDuration: motion.durationFast,
    animationTimingFunction: motion.easeOut,
  },
  panelEmpty: {
    minBlockSize: "52px",
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
    gap: space.md,
    paddingInline: space.lg,
    color: color.secondaryLabel,
    textAlign: "center",
  },
  list: {
    boxSizing: "border-box",
    overflowY: "auto",
    overscrollBehavior: "contain",
    paddingBlock: LIST_INSET,
    paddingInline: LIST_INSET,
  },
  stale: {
    opacity: 0.6,
  },
  row: {
    boxSizing: "border-box",
    blockSize: ROW_HEIGHT,
    display: "flex",
    alignItems: "flex-start",
    gap: space.md,
    paddingBlock: space.sm,
    paddingInline: space.md,
    borderRadius: radius.content,
    cursor: "default",
    userSelect: "none",
    backgroundColor: { default: "transparent", ":hover": color.controlHover },
    transitionProperty: "background-color",
    transitionDuration: motion.durationFast,
  },
  rowActive: {
    backgroundColor: { default: color.controlPressed, ":hover": color.controlPressed },
    outlineWidth: { default: 0, "@media (forced-colors: active)": "2px" },
    outlineStyle: "solid",
    outlineColor: { default: "transparent", "@media (forced-colors: active)": "Highlight" },
    outlineOffset: "-2px",
  },
  avatar: {
    flexShrink: 0,
    display: "inline-flex",
    inlineSize: size.avatar,
    blockSize: size.avatar,
  },
  rowText: {
    flexGrow: 1,
    minInlineSize: 0,
    display: "flex",
    flexDirection: "column",
    gap: space.xxs,
  },
  rowHeader: {
    display: "flex",
    alignItems: "baseline",
    gap: space.md,
  },
  sender: {
    flexGrow: 1,
    minInlineSize: 0,
    overflow: "hidden",
    textOverflow: "ellipsis",
    whiteSpace: "nowrap",
    fontSize: font.sizeCallout,
    fontWeight: font.weightSemibold,
    color: color.label,
    textAlign: "start",
  },
  date: {
    flexShrink: 0,
    fontSize: font.sizeCaption,
    color: color.secondaryLabel,
  },
  snippet: {
    overflow: "hidden",
    whiteSpace: "nowrap",
    textOverflow: "ellipsis",
    fontSize: font.sizeCallout,
    color: color.secondaryLabel,
    textAlign: "start",
  },
  mark: {
    backgroundColor: { default: "transparent", "@media (forced-colors: active)": "Mark" },
    color: { default: color.label, "@media (forced-colors: active)": "MarkText" },
    fontWeight: font.weightSemibold,
    textDecorationLine: { default: "none", "@media (forced-colors: active)": "underline" },
  },
  footer: {
    boxSizing: "border-box",
    blockSize: FOOTER_HEIGHT,
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
    gap: space.sm,
    paddingInline: space.lg,
    fontSize: font.sizeCallout,
    color: color.secondaryLabel,
    whiteSpace: "nowrap",
    overflow: "hidden",
    textOverflow: "ellipsis",
  },
})

const dynamic = stylex.create({
  listHeight: (height: number) => ({
    // Up to seven rows; never more than half the viewport, so a short window keeps the chat visible.
    maxBlockSize: `min(${height}px, 50vh)`,
  }),
  spacer: (height: number) => ({
    blockSize: `${height}px`,
  }),
})
