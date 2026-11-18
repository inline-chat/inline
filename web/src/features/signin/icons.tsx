/** Glyphs for the sign-in screen, in `currentColor`, hidden from assistive technology. */

import { color } from "@inline/ui/tokens/color.stylex"
import * as stylex from "@stylexjs/stylex"

/** The Inline mark (landing/public/inline-logo.svg), drawn in the current text color. */
export function InlineMark(props: { size: number }) {
  return (
    <svg
      width={props.size}
      height={props.size}
      viewBox="0 0 54 54"
      fill="none"
      aria-hidden="true"
      focusable="false"
      {...stylex.props(styles.block)}
    >
      <rect x="5" y="5" width="44" height="44" rx="16" stroke="currentColor" strokeWidth="10" />
      <rect x="17" y="17" width="10" height="20" rx="4" fill="currentColor" />
    </svg>
  )
}

/** Points to the inline start ("back"); mirrored in right to left. */
export function BackIcon() {
  return (
    <svg
      width="16"
      height="16"
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.6"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
      {...stylex.props(styles.block, styles.mirror)}
    >
      <path d="M10 3.5L5.5 8 10 12.5" />
    </svg>
  )
}

/** A filled circle with an exclamation mark, for errors. */
export function ErrorIcon() {
  return (
    <svg width="16" height="16" viewBox="0 0 16 16" aria-hidden="true" focusable="false" {...stylex.props(styles.block)}>
      <circle cx="8" cy="8" r="7" fill="currentColor" />
      <path d="M8 4.5v4.2" strokeWidth="1.7" strokeLinecap="round" {...stylex.props(styles.knockoutStroke)} />
      <circle cx="8" cy="11.2" r="1" {...stylex.props(styles.knockoutFill)} />
    </svg>
  )
}

/** A filled circle with a check mark, for success. */
export function SuccessIcon(props: { size?: number }) {
  const size = props.size ?? 16
  return (
    <svg width={size} height={size} viewBox="0 0 16 16" aria-hidden="true" focusable="false" {...stylex.props(styles.block)}>
      <circle cx="8" cy="8" r="7" fill="currentColor" />
      <path
        d="M4.8 8.3l2.2 2.2 4.2-4.6"
        fill="none"
        strokeWidth="1.7"
        strokeLinecap="round"
        strokeLinejoin="round"
        {...stylex.props(styles.knockoutStroke)}
      />
    </svg>
  )
}

const styles = stylex.create({
  block: { display: "block", flexShrink: 0 },
  /** The mark cut out of a filled glyph. */
  knockoutStroke: { stroke: color.onAccent },
  knockoutFill: { fill: color.onAccent },
  mirror: { transform: { default: null, ":dir(rtl)": "scaleX(-1)" } },
})
