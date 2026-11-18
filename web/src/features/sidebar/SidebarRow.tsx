/**
 * One recycled row (a slot). It stays mounted and swaps which chat it shows
 * (`controller.slot(i)`), so scrolling reuses the DOM: text and attributes
 * change, nothing mounts. It reads only its slot, its item and whether it is
 * the context menu's target, so a change to one chat renders one row and a
 * reorder renders none: the controller positions rows from outside. While
 * the list scrolls fast, a row entering is drawn lite (avatar color and
 * title) and filled in when scrolling settles.
 *
 * Layout from the Mac row (`SidebarNativeRowView`, `Theme`): painted box
 * inset 8 px, radius 10, content inset 11 px, icon then 8 px, title 13 px,
 * preview 11 px, unread dot 5 px centered in the leading inset.
 */

import { useElement, useSignal } from "@inline/reactive/react"
import { countRender } from "@inline/reactive/react/testing"
import { color } from "@inline/ui/tokens/color.stylex"
import { font } from "@inline/ui/tokens/font.stylex"
import { motion } from "@inline/ui/tokens/motion.stylex"
import { radius } from "@inline/ui/tokens/radius.stylex"
import type { AvatarInput, SidebarItem } from "@inline/view/features"
import * as stylex from "@stylexjs/stylex"
import { memo } from "react"
import type { SidebarActivityStatus } from "./activity"
import { avatarFace } from "./avatar"
import { PinIcon } from "./icons"
import { badgeText, DRAFT_LABEL, rowLabel } from "./labels"
import type { SidebarController } from "./sidebar-controller"

/** Mac `UnreadBadgeStyle`: a trailing count, or a leading dot. */
export type UnreadStyle = "count" | "dot"

export type SidebarRowProps = {
  controller: SidebarController
  slot: number
  unreadStyle: UnreadStyle
}

export const SidebarRow = memo(function SidebarRow(props: SidebarRowProps) {
  countRender("sidebar:row")
  const controller = props.controller
  const view = useSignal(controller.slot(props.slot))
  const item = useSignal(controller.itemOf(view.key))
  const contextTarget = useSignal(controller.contextTargetOf(view.key))
  const activity = useSignal(controller.activityOf(view.key))
  const ref = useElement(controller.slotPart(props.slot))
  const compact = !controller.metrics.showsPreview
  const size = compact ? styles.rowCompact : styles.rowStandard
  if (view.key === undefined) return <div ref={ref} hidden {...stylex.props(styles.row, size, styles.empty)} />
  if (!item) return <div ref={ref} aria-label="Chat" {...stylex.props(styles.row, size)} />
  if (view.lite) {
    const face = avatarFace(item.title, item.avatar.seed)
    return (
      <div
        ref={ref}
        aria-label={item.title}
        aria-selected={item.selected}
        {...stylex.props(styles.row, size, item.selected && styles.selected)}
      >
        <span
          aria-hidden="true"
          {...stylex.props(
            styles.avatar,
            compact ? styles.avatarCompact : styles.avatarStandard,
            dynamic.colors(face.colors.gradientTop, face.colors.background, face.colors.border),
          )}
        />
        <div aria-hidden="true" {...stylex.props(styles.text)}>
          <span dir="auto" {...stylex.props(styles.title)}>
            {item.title}
          </span>
        </div>
      </div>
    )
  }
  const dot = props.unreadStyle === "dot"
  const trailing = <Trailing item={item} showCount={!dot} />
  return (
    <div
      ref={ref}
      aria-label={rowLabel(item, activity?.text)}
      aria-selected={item.selected}
      {...stylex.props(
        styles.row,
        size,
        item.selected && styles.selected,
        contextTarget && styles.contextTarget,
      )}
    >
      {dot && item.hasUnread && (
        <span aria-hidden="true" {...stylex.props(styles.leadingDot, item.prominent ? styles.prominentFill : styles.mutedFill)} />
      )}
      <SidebarAvatar avatar={item.avatar} title={item.title} compact={compact} />
      <div aria-hidden="true" {...stylex.props(styles.text)}>
        <div {...stylex.props(styles.line)}>
          <span dir="auto" {...stylex.props(styles.title)}>
            {item.title}
          </span>
          {compact && activity && <ActivityIndicator kind={activity.kind} />}
          {compact ? trailing : !item.hasUnread && item.pinned && <PinIcon style={styles.pin} />}
        </div>
        {!compact && (
          <div {...stylex.props(styles.line, styles.previewLine)}>
            {activity ? <ActivityPreview status={activity} /> : <Preview item={item} />}
            {item.hasUnread && trailing}
          </div>
        )}
      </div>
    </div>
  )
})

/** The trailing accessory: the unread count (or a dot for a mark), else a pin. */
function Trailing(props: { item: SidebarItem; showCount: boolean }) {
  const item = props.item
  if (item.hasUnread && props.showCount) {
    const tone = item.prominent ? styles.prominentFill : styles.mutedFill
    if (item.unreadCount > 0) return <span {...stylex.props(styles.badge, tone)}>{badgeText(item.unreadCount)}</span>
    return <span {...stylex.props(styles.markDot, tone)} />
  }
  if (!item.hasUnread && item.pinned) return <PinIcon style={styles.pin} />
  return null
}

function Preview(props: { item: SidebarItem }) {
  const preview = props.item.preview
  if (preview.kind === "draft") {
    return (
      <span {...stylex.props(styles.preview)}>
        <span {...stylex.props(styles.draftLabel)}>{DRAFT_LABEL}</span> <bdi>{preview.text}</bdi>
      </span>
    )
  }
  if (preview.kind === "message") {
    return (
      <span dir="auto" {...stylex.props(styles.preview)}>
        {preview.text}
      </span>
    )
  }
  return <span {...stylex.props(styles.preview)} />
}

/**
 * The preview line while someone composes (Mac `SidebarNativeComposeActivityView`
 * in text mode): the indicator, 5 px, then the activity in the accent color.
 */
function ActivityPreview(props: { status: SidebarActivityStatus }) {
  return (
    <span {...stylex.props(styles.activityLine)}>
      <ActivityIndicator kind={props.status.kind} />
      <span {...stylex.props(styles.preview, styles.activityText)}>
        {props.status.text}
      </span>
    </span>
  )
}

/**
 * The Mac's 16 by 12 activity indicator: three dots that bob for typing and
 * sending, three bars that pulse for recording, a turning ring for agent
 * work. Still under reduced motion.
 */
function ActivityIndicator(props: { kind: SidebarActivityStatus["kind"] }) {
  if (props.kind === "working") {
    return (
      <span aria-hidden="true" {...stylex.props(styles.indicator)}>
        <span {...stylex.props(styles.ring)} />
      </span>
    )
  }
  const bars = props.kind === "recording"
  return (
    <span aria-hidden="true" {...stylex.props(styles.indicator)}>
      <span {...stylex.props(bars ? styles.bar : styles.dot, bars ? styles.bar1 : styles.dot1)} />
      <span {...stylex.props(bars ? styles.bar : styles.dot, bars ? styles.bar2 : styles.dot2)} />
      <span {...stylex.props(bars ? styles.bar : styles.dot, bars ? styles.bar3 : styles.dot3)} />
    </span>
  )
}

/**
 * A user's photo or initials on their color, or a thread's emoji (bare in
 * compact rows, as on the Mac) or initials. The box has its size before any
 * image loads.
 */
export function SidebarAvatar(props: { avatar: AvatarInput; title: string; compact: boolean }) {
  const avatar = props.avatar
  const sizeStyle = props.compact ? styles.avatarCompact : styles.avatarStandard
  if (avatar.kind === "user" && avatar.photoUrl) {
    return (
      <span aria-hidden="true" {...stylex.props(styles.avatar, sizeStyle, styles.avatarPhoto)}>
        <img src={avatar.photoUrl} alt="" draggable={false} loading="lazy" decoding="async" {...stylex.props(styles.avatarImage)} />
      </span>
    )
  }
  if (avatar.kind === "chat" && avatar.emoji) {
    return (
      <span
        aria-hidden="true"
        {...stylex.props(styles.avatar, sizeStyle, props.compact ? styles.emojiBare : styles.emojiBackground)}
      >
        {avatar.emoji}
      </span>
    )
  }
  const face = avatarFace(props.title, avatar.seed)
  return (
    <span
      aria-hidden="true"
      {...stylex.props(
        styles.avatar,
        sizeStyle,
        styles.initials,
        dynamic.colors(face.colors.gradientTop, face.colors.background, face.colors.border),
      )}
    >
      {face.initials}
    </span>
  )
}

const bob = stylex.keyframes({
  from: { transform: "translateY(0)" },
  to: { transform: "translateY(-2px)" },
})
const pulse = stylex.keyframes({
  from: { transform: "scaleY(0.45)" },
  to: { transform: "scaleY(1)" },
})
const spin = stylex.keyframes({
  from: { transform: "rotate(0deg)" },
  to: { transform: "rotate(360deg)" },
})

const styles = stylex.create({
  activityLine: {
    display: "flex",
    alignItems: "center",
    gap: "5px",
    flexGrow: 1,
    flexShrink: 1,
    minInlineSize: 0,
  },
  activityText: { color: color.accent },
  indicator: {
    flexShrink: 0,
    display: "inline-flex",
    alignItems: "center",
    gap: "2px",
    inlineSize: "16px",
    blockSize: "12px",
    color: color.accent,
    forcedColorAdjust: "auto",
  },
  dot: {
    inlineSize: "3px",
    blockSize: "3px",
    borderRadius: radius.pill,
    backgroundColor: "currentColor",
    animationName: { default: bob, "@media (prefers-reduced-motion: reduce)": "none" },
    animationDuration: "0.37s",
    animationTimingFunction: "ease-in-out",
    animationDirection: "alternate",
    animationIterationCount: "infinite",
  },
  dot1: { animationDelay: "0s" },
  dot2: { animationDelay: "0.1s" },
  dot3: { animationDelay: "0.2s" },
  bar: {
    inlineSize: "2.2px",
    borderRadius: radius.pill,
    backgroundColor: "currentColor",
    animationName: { default: pulse, "@media (prefers-reduced-motion: reduce)": "none" },
    animationDuration: "0.37s",
    animationTimingFunction: "ease-in-out",
    animationDirection: "alternate",
    animationIterationCount: "infinite",
  },
  bar1: { blockSize: "5px", animationDelay: "0s" },
  bar2: { blockSize: "8px", animationDelay: "0.25s" },
  bar3: { blockSize: "11px", animationDelay: "0.5s" },
  ring: {
    inlineSize: "8.75px",
    blockSize: "8.75px",
    marginInline: "auto",
    boxSizing: "border-box",
    borderWidth: "1.25px",
    borderStyle: "solid",
    borderColor: "currentColor",
    borderBlockStartColor: "transparent",
    borderRadius: radius.pill,
    animationName: { default: spin, "@media (prefers-reduced-motion: reduce)": "none" },
    animationDuration: "0.8s",
    animationTimingFunction: "linear",
    animationIterationCount: "infinite",
  },
  row: {
    position: "absolute",
    top: "0.5px",
    insetInlineStart: "8px",
    insetInlineEnd: "8px",
    boxSizing: "border-box",
    display: "flex",
    alignItems: "center",
    gap: "8px",
    paddingInlineStart: "11px",
    paddingInlineEnd: "6px",
    borderRadius: radius.sidebarItem,
    color: color.label,
    cursor: "default",
    userSelect: "none",
    WebkitUserSelect: "none",
    backgroundColor: {
      default: "transparent",
      ":hover": color.controlHover,
    },
    outline: {
      default: "none",
      ":focus-visible": `2px solid ${color.focusRing}`,
    },
    outlineOffset: "-2px",
    transitionProperty: "background-color",
    transitionDuration: motion.durationFast,
    // Rows move with `transform`; keep them on their own layer while scrolling.
    willChange: "transform",
    contain: "layout paint style",
  },
  rowStandard: { height: "39px" },
  rowCompact: { height: "29px" },
  empty: { display: "none" },
  selected: {
    backgroundColor: {
      default: color.controlPressed,
      "@media (prefers-contrast: more)": color.unemphasizedSelectedContentBackground,
    },
    outline: {
      default: "none",
      ":focus-visible": `2px solid ${color.focusRing}`,
      "@media (forced-colors: active)": "2px solid Highlight",
    },
  },
  contextTarget: {
    boxShadow: `inset 0 0 0 2px ${color.accent}`,
  },
  leadingDot: {
    position: "absolute",
    insetInlineStart: "3px",
    top: "50%",
    width: "5px",
    height: "5px",
    marginTop: "-2.5px",
    borderRadius: radius.pill,
  },
  prominentFill: { backgroundColor: color.prominent, color: color.onAccent },
  mutedFill: { backgroundColor: color.gray, color: color.onAccent },
  text: {
    display: "flex",
    flexDirection: "column",
    justifyContent: "center",
    gap: "1px",
    flexGrow: 1,
    flexShrink: 1,
    minWidth: 0,
  },
  line: {
    display: "flex",
    alignItems: "center",
    gap: "6px",
    minWidth: 0,
  },
  previewLine: { gap: "5px" },
  title: {
    flexGrow: 1,
    flexShrink: 1,
    minWidth: 0,
    overflow: "hidden",
    textOverflow: "ellipsis",
    whiteSpace: "nowrap",
    fontSize: font.sizeBody,
    lineHeight: "16px",
  },
  preview: {
    flexGrow: 1,
    flexShrink: 1,
    minWidth: 0,
    overflow: "hidden",
    textOverflow: "ellipsis",
    whiteSpace: "nowrap",
    fontSize: font.sizeSubheadline,
    lineHeight: "14px",
    color: color.secondaryLabel,
  },
  draftLabel: { color: color.destructive },
  badge: {
    flexShrink: 0,
    display: "inline-flex",
    alignItems: "center",
    justifyContent: "center",
    minWidth: "16px",
    height: "16px",
    paddingInline: "5px",
    boxSizing: "border-box",
    borderRadius: radius.pill,
    fontSize: "10.5px",
    fontWeight: font.weightSemibold,
    fontVariantNumeric: "tabular-nums",
    lineHeight: 1,
    forcedColorAdjust: "none",
  },
  markDot: {
    flexShrink: 0,
    width: "8px",
    height: "8px",
    borderRadius: radius.pill,
    forcedColorAdjust: "none",
  },
  pin: { flexShrink: 0, color: color.tertiaryLabel },
  avatar: {
    flexShrink: 0,
    display: "inline-flex",
    alignItems: "center",
    justifyContent: "center",
    overflow: "hidden",
    borderRadius: radius.pill,
    lineHeight: 1,
  },
  avatarStandard: { width: "30px", height: "30px", fontSize: "12px" },
  avatarCompact: { width: "22px", height: "22px", fontSize: "9px" },
  avatarPhoto: { backgroundColor: color.controlTrack },
  avatarImage: { width: "100%", height: "100%", objectFit: "cover" },
  emojiBackground: { backgroundColor: color.quaternaryLabel, fontSize: "16px" },
  emojiBare: { fontSize: "16px" },
  initials: {
    color: "#ffffff",
    fontWeight: font.weightSemibold,
    letterSpacing: "0.02em",
    forcedColorAdjust: "none",
  },
})

const dynamic = stylex.create({
  colors: (top: string, bottom: string, border: string) => ({
    backgroundImage: `linear-gradient(to bottom, ${top}, ${bottom})`,
    boxShadow: `inset 0 0 0 0.5px ${border}`,
  }),
})
