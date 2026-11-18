/** Small display primitives: Kbd, Badge, Avatar, Progress, Separator, ScrollArea. */

import * as stylex from "@stylexjs/stylex"
import type { ReactNode } from "react"
import { avatarStyle, initials } from "../avatar/avatar"
import { color } from "../tokens/color.stylex"
import { font } from "../tokens/font.stylex"
import { motion } from "../tokens/motion.stylex"
import { radius } from "../tokens/radius.stylex"
import { size } from "../tokens/size.stylex"
import { space } from "../tokens/space.stylex"

/** A key or chord, e.g. <Kbd keys={["⌘", "K"]} />. */
export function Kbd(props: { keys: readonly string[]; label?: string }) {
  return (
    <kbd aria-label={props.label} {...stylex.props(styles.kbdGroup)}>
      {props.keys.map((key, index) => (
        <kbd key={`${key}-${index}`} {...stylex.props(styles.kbd)}>
          {key}
        </kbd>
      ))}
    </kbd>
  )
}

export type BadgeTone = "neutral" | "accent" | "success" | "warning" | "danger"

/** A count or short status. Counts above `max` show as "max+". */
export function Badge(props: { children?: ReactNode; count?: number; max?: number; tone?: BadgeTone; label?: string }) {
  const content =
    props.count === undefined ? props.children : props.count > (props.max ?? 99) ? `${props.max ?? 99}+` : props.count
  return (
    <span aria-label={props.label} {...stylex.props(styles.badge, badgeTones[props.tone ?? "neutral"])}>
      {content}
    </span>
  )
}

export type AvatarSize = "small" | "regular" | "large"

/**
 * A person or chat image, falling back to initials on the Apple apps'
 * color for `seed` (see avatarSeed). The image reserves its box before it loads.
 */
export function Avatar(props: { name: string; seed?: string; src?: string; size?: AvatarSize; label?: string }) {
  const palette = avatarStyle(props.seed ?? props.name)
  const avatarSize = props.size ?? "regular"
  return (
    <span
      role="img"
      aria-label={props.label ?? props.name}
      {...stylex.props(
        styles.avatar,
        avatarSizes[avatarSize],
        !props.src && dynamic.avatarColors(palette.gradientTop, palette.background, palette.border),
      )}
    >
      {props.src ? (
        <img src={props.src} alt="" draggable={false} {...stylex.props(styles.avatarImage)} />
      ) : (
        <span aria-hidden="true">{initials(props.name)}</span>
      )}
    </span>
  )
}

/** Determinate when `value` is given (0..1), indeterminate otherwise. */
export function Progress(props: { value?: number; label: string; variant?: "bar" | "spinner" }) {
  const determinate = props.value !== undefined
  const value = Math.min(1, Math.max(0, props.value ?? 0))
  if (props.variant === "spinner") {
    return (
      <span
        role="progressbar"
        aria-label={props.label}
        aria-valuemin={determinate ? 0 : undefined}
        aria-valuemax={determinate ? 100 : undefined}
        aria-valuenow={determinate ? Math.round(value * 100) : undefined}
        {...stylex.props(styles.spinner)}
      />
    )
  }
  return (
    <span
      role="progressbar"
      aria-label={props.label}
      aria-valuemin={determinate ? 0 : undefined}
      aria-valuemax={determinate ? 100 : undefined}
      aria-valuenow={determinate ? Math.round(value * 100) : undefined}
      {...stylex.props(styles.track)}
    >
      <span
        {...stylex.props(styles.fill, determinate ? dynamic.fillScale(value) : styles.indeterminate)}
      />
    </span>
  )
}

export function Separator(props: { orientation?: "horizontal" | "vertical" }) {
  const vertical = props.orientation === "vertical"
  return (
    <div
      role="separator"
      aria-orientation={vertical ? "vertical" : undefined}
      {...stylex.props(vertical ? styles.separatorVertical : styles.separatorHorizontal)}
    />
  )
}

/**
 * A scrolling region with native scrolling and thin, theme-colored
 * scrollbars. Native scrolling keeps momentum, keyboard and accessibility.
 */
export function ScrollArea(props: { children: ReactNode; label?: string; style?: stylex.StyleXStyles }) {
  return (
    <div
      tabIndex={0}
      role={props.label ? "region" : undefined}
      aria-label={props.label}
      {...stylex.props(styles.scrollArea, props.style)}
    >
      {props.children}
    </div>
  )
}

const spin = stylex.keyframes({ to: { transform: "rotate(360deg)" } })
const slide = stylex.keyframes({
  from: { transform: "translateX(-100%)" },
  to: { transform: "translateX(250%)" },
})

const styles = stylex.create({
  kbdGroup: { display: "inline-flex", gap: space.xxs, fontFamily: "inherit" },
  kbd: {
    display: "inline-flex",
    alignItems: "center",
    justifyContent: "center",
    minWidth: "18px",
    height: "18px",
    paddingInline: space.xs,
    boxSizing: "border-box",
    fontFamily: font.familySystem,
    fontSize: font.sizeSubheadline,
    color: color.secondaryLabel,
    backgroundColor: color.controlHover,
    borderRadius: radius.small,
    boxShadow: `inset 0 -1px 0 ${color.separator}`,
  },
  badge: {
    display: "inline-flex",
    alignItems: "center",
    justifyContent: "center",
    minWidth: "18px",
    height: "18px",
    paddingInline: space.sm,
    boxSizing: "border-box",
    borderRadius: radius.pill,
    fontSize: font.sizeSubheadline,
    fontWeight: font.weightSemibold,
    fontVariantNumeric: "tabular-nums",
    lineHeight: 1,
  },
  avatar: {
    display: "inline-flex",
    alignItems: "center",
    justifyContent: "center",
    flexShrink: 0,
    overflow: "hidden",
    borderRadius: radius.pill,
    color: "#ffffff",
    fontWeight: font.weightSemibold,
    userSelect: "none",
    backgroundColor: color.controlTrack,
  },
  avatarImage: { width: "100%", height: "100%", objectFit: "cover" },
  track: {
    position: "relative",
    display: "block",
    width: "100%",
    height: "4px",
    overflow: "hidden",
    borderRadius: radius.pill,
    backgroundColor: color.controlTrack,
  },
  fill: {
    position: "absolute",
    insetBlock: 0,
    insetInlineStart: 0,
    width: "100%",
    borderRadius: radius.pill,
    backgroundColor: color.accent,
    transformOrigin: { default: "left center", ":dir(rtl)": "right center" },
    transitionProperty: "transform",
    transitionDuration: motion.durationNormal,
  },
  indeterminate: {
    width: { default: "40%", "@media (prefers-reduced-motion: reduce)": "100%" },
    opacity: { default: null, "@media (prefers-reduced-motion: reduce)": 0.4 },
    // Under reduced motion the bar stays still: a dimmed full track, not a 40% fill that reads as determinate.
    animationName: { default: slide, "@media (prefers-reduced-motion: reduce)": "none" },
    animationDuration: "1.2s",
    animationIterationCount: "infinite",
    animationTimingFunction: motion.easeStandard,
  },
  spinner: {
    display: "inline-block",
    width: size.icon,
    height: size.icon,
    boxSizing: "border-box",
    borderRadius: radius.pill,
    borderWidth: "2px",
    borderStyle: "solid",
    borderColor: color.controlTrack,
    borderTopColor: color.secondaryLabel,
    // Under reduced motion the ring stays still (the role and label still say "busy").
    animationName: { default: spin, "@media (prefers-reduced-motion: reduce)": "none" },
    animationDuration: "0.8s",
    animationIterationCount: "infinite",
    animationTimingFunction: "linear",
  },
  separatorHorizontal: { height: "1px", width: "100%", backgroundColor: color.separator },
  separatorVertical: { width: "1px", alignSelf: "stretch", backgroundColor: color.separator },
  scrollArea: {
    overflow: "auto",
    overscrollBehavior: "contain",
    scrollbarWidth: "thin",
    scrollbarColor: `${color.tertiaryLabel} transparent`,
    outline: "none",
  },
})

const badgeTones = stylex.create({
  neutral: { backgroundColor: color.controlTrack, color: color.label },
  accent: { backgroundColor: color.accent, color: color.onAccent },
  success: { backgroundColor: color.green, color: color.onAccent },
  warning: { backgroundColor: color.orange, color: color.onAccent },
  danger: { backgroundColor: color.red, color: color.onAccent },
})

const avatarSizes = stylex.create({
  small: { width: size.avatarSmall, height: size.avatarSmall, fontSize: "8px" },
  regular: { width: size.avatar, height: size.avatar, fontSize: font.sizeSubheadline },
  large: { width: size.avatarLarge, height: size.avatarLarge, fontSize: font.sizeTitle3 },
})

const dynamic = stylex.create({
  avatarColors: (top: string, bottom: string, border: string) => ({
    backgroundImage: `linear-gradient(to bottom, ${top}, ${bottom})`,
    boxShadow: `inset 0 0 0 0.5px ${border}`,
  }),
  fillScale: (value: number) => ({ transform: `scaleX(${value})` }),
})
