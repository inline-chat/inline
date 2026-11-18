/**
 * The sidebar region: header slot, mode switch, the chat list, footer slot.
 * The list is windowed (see README.md, "Scale"); its controller owns
 * keyboard, focus, positioning and the "unread below" state, and this file
 * only renders. See README.md for the props and the rules a caller keeps.
 */

import type { ReadSignal } from "@inline/reactive"
import { useElement, useModel, useSignal } from "@inline/reactive/react"
import { countRender } from "@inline/reactive/react/testing"
import { LazyMenuContent } from "@inline/ui/react"
import { color } from "@inline/ui/tokens/color.stylex"
import { font } from "@inline/ui/tokens/font.stylex"
import { motion } from "@inline/ui/tokens/motion.stylex"
import { radius } from "@inline/ui/tokens/radius.stylex"
import { shadow } from "@inline/ui/tokens/shadow.stylex"
import type { OS } from "@inline/view"
import type { SidebarModel } from "@inline/view/features"
import * as stylex from "@stylexjs/stylex"
import { memo, type ReactNode } from "react"
import type { SidebarActions } from "./actions"
import type { SidebarTypingSource } from "./activity"
import type { SidebarDensity } from "./geometry"
import type { SidebarHandle } from "./handle"
import { ArrowDownIcon } from "./icons"
import type { OpenIntentMap } from "./keyboard"
import { badgeText, emptyText, LOADING_LABEL, modeLabels, switchModes, unreadBelowLabel, unreadBelowValue } from "./labels"
import { SidebarController, type SidebarOpenEvent } from "./sidebar-controller"
import { SidebarRow, type UnreadStyle } from "./SidebarRow"

export type SidebarViewProps = {
  /** The session's sidebar model (`session.sidebar`). */
  model: SidebarModel
  /** Row size, as the Mac's "Item size" view option. Default "standard". Changing it rebuilds the list's controller. */
  density?: SidebarDensity
  /** Unread as a trailing count or a leading dot (Mac `UnreadBadgeStyle`). Default "count". */
  unreadStyle?: UnreadStyle
  /**
   * True once the core answered the current mode's list. Keep it stable (one
   * signal for the session). Without it an empty list shows the empty state at once.
   */
  ready?: ReadSignal<boolean>
  /** Row actions for the context menu. Without it, secondary click shows the browser's menu. */
  actions?: SidebarActions
  /**
   * Who is composing in each row's chat: a signal per item, or undefined.
   * `(item) => activityIndex.forChat(item.chatId)` with the typing feature's
   * `createComposeActivityIndex`. A change renders that row alone.
   */
  typingFor?: SidebarTypingSource
  /** After a row opened its chat. Focus stays in the list unless this moves it. */
  onOpened?: (event: SidebarOpenEvent) => void
  /** Replace the modifier-to-intent map (`openIntentFor`). */
  openIntent?: OpenIntentMap
  /** For "focus sidebar" and similar commands. Keep it stable. */
  handle?: SidebarHandle
  /** Defaults to the detected OS. */
  os?: OS
  header?: ReactNode
  footer?: ReactNode
  /** Show the Inbox / All chats switch. Default true. */
  showModeSwitch?: boolean
  /** The list's accessible name. Default "Chats". */
  label?: string
}

export function SidebarView(props: SidebarViewProps) {
  const density = props.density ?? "standard"
  const controller = useModel(
    () =>
      new SidebarController({
        model: props.model,
        density,
        ...(props.ready ? { ready: props.ready } : {}),
        ...(props.handle ? { handle: props.handle } : {}),
        ...(props.os ? { os: props.os } : {}),
        ...(props.label ? { label: props.label } : {}),
      }),
    [props.model, density, props.ready, props.handle, props.os, props.label],
  )
  // Latest callbacks; read when they fire, so inline functions are fine.
  controller.setCallbacks({
    ...(props.actions ? { actions: props.actions } : {}),
    ...(props.typingFor ? { typingFor: props.typingFor } : {}),
    ...(props.onOpened ? { onOpened: props.onOpened } : {}),
    ...(props.openIntent ? { openIntent: props.openIntent } : {}),
  })
  return (
    <div {...stylex.props(styles.root)}>
      {props.header !== undefined && <div {...stylex.props(styles.slot)}>{props.header}</div>}
      {props.showModeSwitch !== false && <ModeSwitch controller={controller} />}
      <SidebarBody controller={controller} unreadStyle={props.unreadStyle ?? "count"} />
      {props.footer !== undefined && <div {...stylex.props(styles.slot, styles.footer)}>{props.footer}</div>}
    </div>
  )
}

/** Inbox or All chats, bound to the model's mode. */
function ModeSwitch(props: { controller: SidebarController }) {
  const mode = useSignal(props.controller.mode)
  return (
    <div role="group" aria-label="Show" {...stylex.props(styles.modeSwitch)}>
      {switchModes.map((option) => (
        <button
          key={option}
          type="button"
          aria-pressed={mode === option}
          onClick={() => props.controller.setMode(option)}
          {...stylex.props(styles.modeButton, mode === option && styles.modeButtonOn)}
        >
          {modeLabels[option]}
        </button>
      ))}
    </div>
  )
}

function SidebarBody(props: { controller: SidebarController; unreadStyle: UnreadStyle }) {
  const status = useSignal(props.controller.status)
  const scroller = useElement(props.controller.scroller)
  return (
    <div {...stylex.props(styles.body)}>
      <div ref={scroller} {...stylex.props(styles.scroller)}>
        <SidebarList controller={props.controller} unreadStyle={props.unreadStyle} />
        {status === "loading" && <FirstLoad controller={props.controller} />}
        {status === "empty" && <EmptyState controller={props.controller} />}
      </div>
      <UnreadBelowButton controller={props.controller} />
      <LazyMenuContent menu={props.controller.contextMenu} />
    </div>
  )
}

const SidebarList = memo(function SidebarList(props: { controller: SidebarController; unreadStyle: UnreadStyle }) {
  countRender("sidebar:list")
  const slots = useSignal(props.controller.slotCount)
  const height = useSignal(props.controller.contentHeight)
  const busy = useSignal(props.controller.busy)
  const listbox = useElement(props.controller.listbox)
  // Recycled rows, keyed by slot: scrolling changes what a slot shows, never which slots exist.
  const rows = []
  for (let slot = 0; slot < slots; slot++) {
    rows.push(<SidebarRow key={slot} controller={props.controller} slot={slot} unreadStyle={props.unreadStyle} />)
  }
  return (
    <div ref={listbox} aria-busy={busy || undefined} {...stylex.props(styles.listbox, dynamic.height(height))}>
      {rows}
    </div>
  )
})

/** Shown only while the core has not answered and nothing local is on screen. Static: no shimmer. */
function FirstLoad(props: { controller: SidebarController }) {
  const compact = !props.controller.metrics.showsPreview
  const rows = Array.from({ length: 10 }, (_, index) => index)
  return (
    <div {...stylex.props(styles.placeholder)}>
      <span {...stylex.props(styles.visuallyHidden)} role="status">
        {LOADING_LABEL}
      </span>
      {rows.map((index) => (
        <div key={index} aria-hidden="true" {...stylex.props(styles.ghostRow, compact ? styles.ghostCompact : styles.ghostStandard)}>
          <span {...stylex.props(styles.ghostAvatar, compact ? styles.ghostAvatarCompact : styles.ghostAvatarStandard)} />
          <span {...stylex.props(styles.ghostLines)}>
            <span {...stylex.props(styles.ghostBar, dynamic.width(`${55 + ((index * 37) % 35)}%`))} />
            {!compact && <span {...stylex.props(styles.ghostBar, styles.ghostBarThin, dynamic.width(`${35 + ((index * 53) % 45)}%`))} />}
          </span>
        </div>
      ))}
    </div>
  )
}

function EmptyState(props: { controller: SidebarController }) {
  const mode = useSignal(props.controller.mode)
  const text = emptyText(mode)
  return (
    <div role="status" {...stylex.props(styles.empty)}>
      <p {...stylex.props(styles.emptyTitle)}>{text.title}</p>
      <p {...stylex.props(styles.emptyBody)}>{text.body}</p>
    </div>
  )
}

/** Mac `SidebarUnreadBelowButton`: shown while prominent unread chats are below the viewport. */
function UnreadBelowButton(props: { controller: SidebarController }) {
  const below = useSignal(props.controller.unreadBelow)
  if (below.count === 0) return null
  return (
    <div {...stylex.props(styles.unreadBelowLane)}>
      <button
        type="button"
        tabIndex={-1}
        title={unreadBelowLabel}
        aria-label={unreadBelowLabel}
        aria-description={unreadBelowValue(below.count)}
        onClick={() => props.controller.revealUnreadBelow()}
        {...stylex.props(styles.unreadBelow)}
      >
        <ArrowDownIcon />
        <span aria-hidden="true" {...stylex.props(styles.unreadBelowBadge)}>
          {badgeText(below.count)}
        </span>
      </button>
    </div>
  )
}

const appear = stylex.keyframes({
  from: { opacity: 0, transform: "translateY(12px) scale(0.96)" },
  to: { opacity: 1, transform: "none" },
})

const styles = stylex.create({
  root: {
    display: "flex",
    flexDirection: "column",
    blockSize: "100%",
    minBlockSize: 0,
    backgroundColor: color.sidebarBackground,
    color: color.label,
    fontFamily: font.familySystem,
    fontSize: font.sizeBody,
    lineHeight: font.lineHeightBody,
  },
  slot: { flexShrink: 0 },
  footer: {
    borderBlockStartWidth: "1px",
    borderBlockStartStyle: "solid",
    borderBlockStartColor: color.separator,
  },
  modeSwitch: {
    flexShrink: 0,
    display: "flex",
    gap: "2px",
    marginBlock: "6px",
    marginInline: "8px",
    padding: "2px",
    borderRadius: radius.control,
    backgroundColor: color.controlTrack,
  },
  modeButton: {
    flexGrow: 1,
    flexBasis: 0,
    minWidth: 0,
    height: "22px",
    paddingInline: "8px",
    borderWidth: 0,
    borderRadius: radius.small,
    backgroundColor: "transparent",
    color: color.secondaryLabel,
    fontFamily: "inherit",
    fontSize: font.sizeCallout,
    fontWeight: font.weightMedium,
    whiteSpace: "nowrap",
    overflow: "hidden",
    textOverflow: "ellipsis",
    cursor: "default",
    outline: {
      default: "none",
      ":focus-visible": `2px solid ${color.focusRing}`,
    },
    outlineOffset: "1px",
  },
  modeButtonOn: {
    backgroundColor: color.control,
    color: color.label,
    boxShadow: shadow.control,
  },
  body: {
    position: "relative",
    flexGrow: 1,
    flexShrink: 1,
    minBlockSize: 0,
    display: "flex",
    flexDirection: "column",
  },
  scroller: {
    position: "relative",
    flexGrow: 1,
    minBlockSize: 0,
    overflowX: "hidden",
    overflowY: "auto",
    overscrollBehavior: "contain",
    scrollbarWidth: "thin",
    scrollbarColor: `${color.tertiaryLabel} transparent`,
    contain: "strict",
  },
  listbox: {
    position: "relative",
    outline: {
      default: "none",
      ":focus-visible": `2px solid ${color.focusRing}`,
    },
    outlineOffset: "-2px",
  },
  placeholder: {
    position: "absolute",
    insetBlockStart: "6px",
    insetInline: 0,
  },
  ghostRow: {
    display: "flex",
    alignItems: "center",
    gap: "8px",
    paddingInlineStart: "19px",
    paddingInlineEnd: "14px",
  },
  ghostStandard: { height: "40px" },
  ghostCompact: { height: "30px" },
  ghostAvatar: { flexShrink: 0, borderRadius: radius.pill, backgroundColor: color.quaternaryLabel },
  ghostAvatarStandard: { width: "30px", height: "30px" },
  ghostAvatarCompact: { width: "22px", height: "22px" },
  ghostLines: { display: "flex", flexDirection: "column", gap: "5px", flexGrow: 1, minWidth: 0 },
  ghostBar: { display: "block", height: "9px", borderRadius: radius.small, backgroundColor: color.quaternaryLabel },
  ghostBarThin: { height: "7px" },
  empty: {
    position: "absolute",
    insetBlockStart: "40px",
    insetInline: "16px",
    textAlign: "center",
  },
  emptyTitle: {
    margin: 0,
    fontSize: font.sizeBody,
    fontWeight: font.weightSemibold,
    color: color.secondaryLabel,
  },
  emptyBody: {
    marginBlock: "4px 0",
    marginInline: 0,
    fontSize: font.sizeCallout,
    color: color.tertiaryLabel,
  },
  unreadBelowLane: {
    position: "absolute",
    insetInline: 0,
    insetBlockEnd: "8px",
    display: "flex",
    justifyContent: "center",
    pointerEvents: "none",
  },
  unreadBelow: {
    pointerEvents: "auto",
    position: "relative",
    display: "inline-flex",
    alignItems: "center",
    justifyContent: "center",
    width: "28px",
    height: "28px",
    padding: 0,
    borderWidth: 0,
    borderRadius: radius.pill,
    backgroundColor: {
      default: color.popoverBackground,
      ":hover": color.menuBackground,
    },
    boxShadow: shadow.control,
    color: color.secondaryLabel,
    cursor: "default",
    transform: { default: "none", ":active": "scale(0.96)" },
    transitionProperty: "transform",
    transitionDuration: motion.durationFast,
    animationName: appear,
    animationDuration: motion.durationNormal,
    animationTimingFunction: motion.easeOut,
  },
  unreadBelowBadge: {
    position: "absolute",
    insetBlockStart: "-8px",
    // Centered in both directions without a physical translate.
    insetInline: 0,
    marginInline: "auto",
    width: "fit-content",
    minWidth: "15px",
    height: "15px",
    paddingInline: "4px",
    boxSizing: "border-box",
    display: "inline-flex",
    alignItems: "center",
    justifyContent: "center",
    borderRadius: radius.pill,
    backgroundColor: color.prominent,
    color: color.onAccent,
    fontSize: "10px",
    fontWeight: font.weightBold,
    fontVariantNumeric: "tabular-nums",
    lineHeight: 1,
    forcedColorAdjust: "none",
  },
  visuallyHidden: {
    position: "absolute",
    width: "1px",
    height: "1px",
    margin: "-1px",
    padding: 0,
    overflow: "hidden",
    clipPath: "inset(50%)",
    whiteSpace: "nowrap",
    borderWidth: 0,
  },
})

const dynamic = stylex.create({
  height: (value: number) => ({ height: `${value}px` }),
  width: (value: string) => ({ width: value }),
})
