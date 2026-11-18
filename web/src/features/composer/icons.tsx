/** Glyphs for the composer, inline SVG in `currentColor`. */

import * as stylex from "@stylexjs/stylex"

const spin = stylex.keyframes({
  from: { transform: "rotate(0deg)" },
  to: { transform: "rotate(360deg)" },
})

/** The Mac app's `arrow.up` send glyph. Does not mirror: up is up in both directions. */
export function SendIcon(props: { size?: number }) {
  const size = props.size ?? 14
  return (
    <svg width={size} height={size} viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" focusable="false">
      <path d="M8 13V3.5M3.75 7.5L8 3.25l4.25 4.25" />
    </svg>
  )
}

/** A small arc that turns while a send is being accepted; still under reduced motion. */
export function PendingIcon(props: { size?: number }) {
  const size = props.size ?? 14
  return (
    <svg width={size} height={size} viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round" aria-hidden="true" focusable="false" {...stylex.props(styles.spinner)}>
      <path d="M8 2.5a5.5 5.5 0 1 1-5.5 5.5" />
    </svg>
  )
}

const styles = stylex.create({
  spinner: {
    animationName: { default: spin, "@media (prefers-reduced-motion: reduce)": "none" },
    animationDuration: "0.8s",
    animationIterationCount: "infinite",
    animationTimingFunction: "linear",
  },
})

/** "Attach files": a plus, as the Mac composer's menu button. */
export function AttachIcon(props: { size?: number }) {
  const size = props.size ?? 16
  return (
    <svg width={size} height={size} viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth={1.75} strokeLinecap="round" aria-hidden="true" focusable="false">
      <path d="M8 3v10M3 8h10" />
    </svg>
  )
}

/** A file in the attachment strip. */
export function FileIcon(props: { size?: number }) {
  const size = props.size ?? 16
  return (
    <svg width={size} height={size} viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth={1.5} strokeLinejoin="round" aria-hidden="true" focusable="false">
      <path d="M4 1.75h5.25L12.5 5v9.25h-8.5z" />
      <path d="M9 1.75V5.25h3.5" />
    </svg>
  )
}

/** Try again. */
export function RetryIcon(props: { size?: number }) {
  const size = props.size ?? 14
  return (
    <svg width={size} height={size} viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth={1.75} strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" focusable="false">
      <path d="M13 8a5 5 0 1 1-1.5-3.55" />
      <path d="M13 2.75v2.5h-2.5" />
    </svg>
  )
}
