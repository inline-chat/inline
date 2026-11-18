/**
 * Glyphs for message rows, as inline SVG in `currentColor` on a 16 unit grid.
 * Modeled on the SF Symbols the Mac app uses (`clock`, `checkmark`,
 * `exclamationmark.triangle`, `arrow.turn.down.right`, `face.smiling`,
 * `ellipsis`). Purely decorative: the control or row carries the label.
 */

import * as stylex from "@stylexjs/stylex"
import type { ReactNode } from "react"
import type { MessageActionIcon } from "./actions"
import type { StateGlyph } from "./state"

type SvgProps = { size?: number; style?: stylex.StyleXStyles; children: ReactNode }

const Svg = (props: SvgProps) => (
  <svg
    width={props.size ?? 16}
    height={props.size ?? 16}
    viewBox="0 0 16 16"
    fill="none"
    stroke="currentColor"
    strokeWidth={1.5}
    strokeLinecap="round"
    strokeLinejoin="round"
    aria-hidden="true"
    focusable="false"
    {...stylex.props(styles.icon, props.style)}
  >
    {props.children}
  </svg>
)

const statePaths: Record<StateGlyph, ReactNode> = {
  clock: (
    <>
      <circle cx="8" cy="8" r="6" />
      <path d="M8 4.6V8l2.3 1.5" />
    </>
  ),
  check: <path d="M3.2 8.6l3.1 3 6.5-7.2" strokeWidth={1.7} />,
  warning: (
    <>
      <path d="M8 2.2L14.3 13.3H1.7Z" />
      <path d="M8 6.4v3.3" />
      <circle cx="8" cy="11.6" r="0.4" fill="currentColor" />
    </>
  ),
  // A dotted ring: neither the clock of "sending", the check of "sent", nor
  // the triangle of "failed".
  unknown: (
    <>
      <circle cx="8" cy="8" r="6" strokeDasharray="1.6 2.1" />
      <circle cx="8" cy="8" r="1" fill="currentColor" stroke="none" />
    </>
  ),
}

/** The delivery state glyph. */
export const StateIcon = (props: { glyph: StateGlyph; size?: number }) => (
  <Svg size={props.size ?? 12}>{statePaths[props.glyph]}</Svg>
)

const actionPaths: Record<MessageActionIcon, ReactNode> = {
  reply: <path d="M6.5 4L2.5 8l4 4M2.8 8h6.7a4 4 0 014 4v.5" />,
  replyInThread: <path d="M3 2.5v4.2a3 3 0 003 3h7M10 6.5l3 3.2-3 3.2" />,
  react: (
    <>
      <circle cx="8" cy="8" r="6" />
      <path d="M5.6 9.6a3 3 0 004.8 0" />
      <circle cx="6" cy="6.6" r="0.5" fill="currentColor" />
      <circle cx="10" cy="6.6" r="0.5" fill="currentColor" />
    </>
  ),
  copy: (
    <>
      <rect x="5.5" y="5.5" width="8" height="8" rx="1.6" />
      <path d="M10.5 5.5V4a1.5 1.5 0 00-1.5-1.5H4A1.5 1.5 0 002.5 4v5A1.5 1.5 0 004 10.5h1.5" />
    </>
  ),
  copyLink: <path d="M7 9a2.6 2.6 0 003.7 0l2.2-2.2a2.6 2.6 0 00-3.7-3.7l-.8.8M9 7a2.6 2.6 0 00-3.7 0L3.1 9.2a2.6 2.6 0 003.7 3.7l.8-.8" />,
  edit: <path d="M10.8 2.7l2.5 2.5-7.6 7.6-3.2.7.7-3.2zM9.3 4.2l2.5 2.5" />,
  delete: <path d="M2.8 4.3h10.4M6.3 4.3V2.8h3.4v1.5M4.2 4.3l.6 8.6a1 1 0 001 .9h4.4a1 1 0 001-.9l.6-8.6M6.7 6.8v4.4M9.3 6.8v4.4" />,
  resend: <path d="M13 8a5 5 0 11-1.5-3.6M13 2.6v2.6h-2.6" />,
  forward: <path d="M9.5 4l4 4-4 4M13.2 8H6.5a4 4 0 00-4 4v.5" />,
  pin: <path d="M6 2.5h4M6.8 2.5v4L4.5 9.3h7L9.2 6.5v-4M8 9.3v4.2" />,
  select: (
    <>
      <circle cx="8" cy="8" r="6" />
      <path d="M5.4 8.2l1.8 1.8 3.5-3.8" />
    </>
  ),
  more: (
    <>
      <circle cx="3.8" cy="8" r="0.9" fill="currentColor" stroke="none" />
      <circle cx="8" cy="8" r="0.9" fill="currentColor" stroke="none" />
      <circle cx="12.2" cy="8" r="0.9" fill="currentColor" stroke="none" />
    </>
  ),
}

/** An action's icon; actions without one show the "more" dots. */
export const ActionIcon = (props: { icon: MessageActionIcon | undefined; size?: number }) => (
  <Svg size={props.size ?? 15} style={props.icon === "reply" || props.icon === "forward" || props.icon === "replyInThread" ? styles.mirror : undefined}>
    {actionPaths[props.icon ?? "more"]}
  </Svg>
)

const styles = stylex.create({
  icon: { flexShrink: 0, display: "block" },
  mirror: { transform: { default: null, ":dir(rtl)": "scaleX(-1)" } },
})
