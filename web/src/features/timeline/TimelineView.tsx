/**
 * The message list: one scroll container holding a bounded window of real
 * rows in normal document flow. All scroll logic is the timeline
 * controller's (`@inline/timeline`); `TimelineSurface` binds it to the
 * elements rendered here. This file only renders. See README.md.
 *
 * - The list reads keys; each row reads its own item, so a change to one
 *   row's content renders that row only, and appending or prepending renders
 *   only the new rows (rows are `memo`, which the React Compiler alone does
 *   not give list rows).
 * - Nothing here writes the scroll offset or measures layout.
 */

import { useElement, useSignal } from "@inline/reactive/react"
import { countRender } from "@inline/reactive/react/testing"
import type { ItemKey, TimelineItem } from "@inline/timeline"
import { Badge, ChevronDownIcon, IconButton, Progress } from "@inline/ui/react"
import { color } from "@inline/ui/tokens/color.stylex"
import { font } from "@inline/ui/tokens/font.stylex"
import { motion } from "@inline/ui/tokens/motion.stylex"
import { radius } from "@inline/ui/tokens/radius.stylex"
import { shadow } from "@inline/ui/tokens/shadow.stylex"
import { size } from "@inline/ui/tokens/size.stylex"
import { space } from "@inline/ui/tokens/space.stylex"
import * as stylex from "@stylexjs/stylex"
import { memo, type MouseEvent, type ReactNode } from "react"
import { formatLatestCount, latestButtonLabel } from "./format"
import type { TimelineSurface } from "./surface"

export type RenderTimelineItem = (item: TimelineItem) => ReactNode

export type TimelineViewProps = {
  surface: TimelineSurface
  /**
   * Renders one item (message, day separator, unread line). Must be a stable
   * function (module level, or memoized by its owner): every row is
   * re-rendered when it changes. A message row should read its own data by ID
   * and must have no vertical margins (spacing goes inside the row).
   */
  renderItem: RenderTimelineItem
  /** Accessible name of the list. */
  label?: string
  /** Shown when the chat has no messages. */
  empty?: ReactNode
  style?: stylex.StyleXStyles
}

export function TimelineView(props: TimelineViewProps) {
  countRender("timeline:view")
  const rootRef = useElement(props.surface.root)
  return (
    <div ref={rootRef} {...stylex.props(styles.root, props.style)}>
      <TimelineScroller surface={props.surface} renderItem={props.renderItem} label={props.label ?? "Messages"} />
      <TimelineStatus surface={props.surface} empty={props.empty} />
      <LatestButton surface={props.surface} />
    </div>
  )
}

// ---------------------------------------------------------------------------
// Scroll container and rows

function TimelineScroller(props: { surface: TimelineSurface; renderItem: RenderTimelineItem; label: string }) {
  countRender("timeline:scroller")
  const hidden = useSignal(props.surface.controller.hidden)
  const ref = useElement(props.surface.container)
  return (
    <div
      ref={ref}
      // Focusable, so the browser's own keyboard scrolling (Page Up/Down, Home/End, arrows, Space)
      // applies to it and its keydown reaches the DOM host, which reports it to the controller as user input.
      tabIndex={0}
      role="region"
      aria-label={props.label}
      aria-busy={hidden || undefined}
      data-timeline-scroller=""
      {...stylex.props(styles.scroller, hidden ? styles.hidden : styles.revealed)}
    >
      {/* data-timeline-content is CONTENT_ATTRIBUTE: the DOM host's rows are this element's keyed children. */}
      <div data-timeline-content="" {...stylex.props(styles.content)}>
        <OlderEdge surface={props.surface} />
        <TimelineRows surface={props.surface} renderItem={props.renderItem} />
        <NewerEdge surface={props.surface} />
      </div>
    </div>
  )
}

const TimelineRows = memo(function TimelineRows(props: { surface: TimelineSurface; renderItem: RenderTimelineItem }) {
  countRender("timeline:list")
  const keys = useSignal(props.surface.keys)
  return keys.map((key) => <TimelineRow key={key} surface={props.surface} itemKey={key} renderItem={props.renderItem} />)
})

const TimelineRow = memo(function TimelineRow(props: {
  surface: TimelineSurface
  itemKey: ItemKey
  renderItem: RenderTimelineItem
}) {
  countRender("timeline:row")
  const item = useSignal(props.surface.item(props.itemKey))
  const flash = useSignal(props.surface.flash(props.itemKey))
  return (
    <div data-timeline-key={props.itemKey} {...stylex.props(styles.row)}>
      {/* Keyed by the flash number, so each flash restarts the animation. Behind the content, outside layout. */}
      {flash > 0 ? <span key={flash} aria-hidden="true" data-timeline-flash="" {...stylex.props(styles.flash)} /> : null}
      {item ? props.renderItem(item) : null}
    </div>
  )
})

/** Fixed-height reserve above the first row; its height never changes (see chrome.ts). */
function OlderEdge(props: { surface: TimelineSurface }) {
  const state = useSignal(props.surface.olderEdge)
  return (
    <div aria-hidden={state !== "loading"} {...stylex.props(styles.edge)}>
      {state === "loading" ? <Progress variant="spinner" label="Loading older messages" /> : null}
    </div>
  )
}

/** Fixed-height placeholder below the last row while the rendered rows stop short of the live end. */
function NewerEdge(props: { surface: TimelineSurface }) {
  const state = useSignal(props.surface.newerEdge)
  if (state === "none") return null
  return (
    <div aria-hidden={state !== "loading"} {...stylex.props(styles.edge)}>
      {state === "loading" ? <Progress variant="spinner" label="Loading newer messages" /> : null}
    </div>
  )
}

// ---------------------------------------------------------------------------
// Chrome

/** The spinner over a hidden list (after the controller's delay), or the empty state. Overlays: no layout. */
function TimelineStatus(props: { surface: TimelineSurface; empty: ReactNode }) {
  const spinner = useSignal(props.surface.controller.spinner)
  const empty = useSignal(props.surface.empty)
  if (spinner) {
    return (
      <div {...stylex.props(styles.overlay)}>
        <Progress variant="spinner" label="Loading messages" />
      </div>
    )
  }
  if (!empty) return null
  return (
    <div {...stylex.props(styles.overlay)}>
      {props.empty ?? <p {...stylex.props(styles.emptyText)}>No messages yet</p>}
    </div>
  )
}

/** Clicking the button leaves keyboard focus where it was (the composer, usually), as on the Mac. */
const keepFocus = (event: MouseEvent) => event.preventDefault()

/**
 * "Jump to latest", placed like the Mac's: a 34 px circle centered 32 px from
 * the trailing edge, 10 px above the bottom inset. Always mounted and
 * absolutely positioned, so showing it shifts nothing.
 */
function LatestButton(props: { surface: TimelineSurface }) {
  const state = useSignal(props.surface.controller.latestButton)
  const { visible, count } = state
  return (
    <div inert={!visible} {...stylex.props(styles.latest, visible ? styles.latestShown : styles.latestHidden)}>
      <IconButton
        label={latestButtonLabel(count)}
        icon={<ChevronDownIcon size={15} />}
        size="large"
        tabIndex={-1}
        onMouseDown={keepFocus}
        onClick={() => props.surface.controller.jumpToLatest()}
        style={styles.latestButton}
      />
      {count > 0 ? (
        <span aria-hidden="true" {...stylex.props(styles.latestBadge)}>
          <Badge tone="accent">{formatLatestCount(count)}</Badge>
        </span>
      ) : null}
    </div>
  )
}

// ---------------------------------------------------------------------------
// Styles

/**
 * Mac `MessageTableRow.highlight`: 0.2 s to a 20% gray, held 0.4 s, 0.25 s
 * back (850 ms, `FLASH_MS` in surface.ts).
 */
const flashIn = stylex.keyframes({
  "0%": { opacity: 0 },
  "23.5%": { opacity: 1 },
  "70.6%": { opacity: 1 },
  "100%": { opacity: 0 },
})

/** Reduced motion: the same tint for the same time, appearing and leaving without a fade. */
const flashStatic = stylex.keyframes({
  "0%": { opacity: 1 },
  "99.9%": { opacity: 1 },
  "100%": { opacity: 0 },
})

const styles = stylex.create({
  root: {
    position: "relative",
    isolation: "isolate",
    overflow: "hidden",
    minWidth: 0,
    minHeight: 0,
    blockSize: "100%",
    backgroundColor: color.windowBackground,
    color: color.label,
    fontFamily: font.familySystem,
    fontSize: font.sizeBody,
    lineHeight: font.lineHeightBody,
  },
  scroller: {
    position: "absolute",
    inset: 0,
    overflowX: "hidden",
    overflowY: "auto",
    // The controller is the one owner of scroll correction; the browser's anchoring would fight it.
    overflowAnchor: "none",
    overscrollBehavior: "contain",
    scrollbarWidth: "thin",
    scrollbarColor: `${color.tertiaryLabel} transparent`,
    outline: { default: "none", ":focus-visible": `2px solid ${color.focusRing}` },
    outlineOffset: "-2px",
  },
  hidden: {
    // Laid out (the controller places rows while hidden), not painted.
    visibility: "hidden",
    opacity: 0,
  },
  revealed: {
    visibility: "visible",
    opacity: 1,
    // REVEAL_FADE_MS (200 ms ease-out, Mac `revealListAfterLayout`); none under reduced motion.
    transitionProperty: "opacity",
    transitionDuration: { default: "200ms", "@media (prefers-reduced-motion: reduce)": "0s" },
    transitionTimingFunction: motion.easeOut,
  },
  content: {
    display: "flex",
    flexDirection: "column",
    // A short chat sits at the bottom, by the composer.
    justifyContent: "flex-end",
    boxSizing: "border-box",
    minBlockSize: "100%",
    // Mac `messageListBottomInset` (10) plus whatever overlays the bottom (the composer).
    paddingBlockEnd: `calc(10px + var(--timeline-inset-bottom, 0px))`,
  },
  row: {
    position: "relative",
    // Contains the row's own margins, so the row's box is its full height (the host contract: no vertical margins).
    display: "flow-root",
    flexShrink: 0,
    isolation: "isolate",
  },
  flash: {
    position: "absolute",
    inset: 0,
    zIndex: -1,
    pointerEvents: "none",
    backgroundColor: `color-mix(in srgb, ${color.gray} 20%, transparent)`,
    opacity: 0,
    animationName: { default: flashIn, "@media (prefers-reduced-motion: reduce)": flashStatic },
    animationDuration: "850ms",
    animationTimingFunction: { default: "ease-in-out", "@media (prefers-reduced-motion: reduce)": "step-end" },
    animationFillMode: "both",
  },
  edge: {
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
    flexShrink: 0,
    blockSize: "40px",
    overflow: "hidden",
    contain: "strict",
  },
  overlay: {
    position: "absolute",
    inset: 0,
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
    paddingBlockStart: "var(--timeline-inset-top, 0px)",
    paddingBlockEnd: "var(--timeline-inset-bottom, 0px)",
    pointerEvents: "none",
  },
  emptyText: {
    margin: 0,
    color: color.secondaryLabel,
    fontSize: font.sizeBody,
  },
  latest: {
    position: "absolute",
    zIndex: 1,
    // Mac: centered `leadingControlCenterX` (32) from the trailing edge, `messageListBottomInset` (10) above compose.
    insetInlineEnd: `calc(32px - ${size.controlLarge} / 2)`,
    insetBlockEnd: "calc(10px + var(--timeline-inset-bottom, 0px))",
    transformOrigin: "bottom center",
    transitionProperty: "opacity, transform",
    transitionDuration: motion.durationSlow,
    transitionTimingFunction: motion.easeSpring,
  },
  latestShown: {
    opacity: 1,
    transform: "none",
  },
  latestHidden: {
    opacity: 0,
    // Mac `hiddenScale` 0.8 and `hiddenOffset` 6; plain fade under reduced motion (durations are 0 there).
    transform: { default: "translateY(6px) scale(0.8)", "@media (prefers-reduced-motion: reduce)": "none" },
    pointerEvents: "none",
  },
  latestButton: {
    borderRadius: radius.pill,
    backgroundColor: { default: color.popoverBackground, ":hover": color.popoverBackground },
    boxShadow: shadow.control,
    backdropFilter: "blur(20px) saturate(1.6)",
    color: color.label,
  },
  latestBadge: {
    position: "absolute",
    insetBlockStart: `calc(-1 * ${space.sm})`,
    insetInlineEnd: `calc(-1 * ${space.xs})`,
    pointerEvents: "none",
  },
})
