/** Glyphs the sidebar draws. Decorative: the row's label carries their meaning. */

import * as stylex from "@stylexjs/stylex"

type IconProps = { size?: number; style?: stylex.StyleXStyles }

/** A pin, for a pinned chat with nothing unread (Mac `pin.fill`). */
export function PinIcon(props: IconProps) {
  const size = props.size ?? 12
  return (
    <svg width={size} height={size} viewBox="0 0 16 16" aria-hidden="true" focusable="false" {...stylex.props(props.style)}>
      <path
        fill="currentColor"
        d="M10.6 1.4a1 1 0 0 1 1.4 0l2.6 2.6a1 1 0 0 1 0 1.4l-.9.9a1.5 1.5 0 0 1-1.3.4l-1.7 1.7.3 2.4a1 1 0 0 1-.3.8l-.8.8a.75.75 0 0 1-1.06 0L6.6 10.1 3.3 13.4a.6.6 0 0 1-.85-.85L5.75 9.3 3.5 7.06a.75.75 0 0 1 0-1.06l.8-.8a1 1 0 0 1 .8-.3l2.4.3 1.7-1.7a1.5 1.5 0 0 1 .4-1.3z"
      />
    </svg>
  )
}

/** The "unread below" arrow (Mac `arrow.down`). */
export function ArrowDownIcon(props: IconProps) {
  const size = props.size ?? 13
  return (
    <svg width={size} height={size} viewBox="0 0 16 16" aria-hidden="true" focusable="false" {...stylex.props(props.style)}>
      <path
        fill="none"
        stroke="currentColor"
        strokeWidth="1.8"
        strokeLinecap="round"
        strokeLinejoin="round"
        d="M8 2.5v11M3.5 9 8 13.5 12.5 9"
      />
    </svg>
  )
}
