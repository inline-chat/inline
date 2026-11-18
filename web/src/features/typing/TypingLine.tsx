/**
 * A compose status line ("Ada is typing…") in the accent color with the
 * Mac's animated dots; the dots stand still under reduced motion. Renders
 * nothing for no status. The header decides when it shows (rule 15).
 */

import { color } from "@inline/ui/tokens/color.stylex"
import { font } from "@inline/ui/tokens/font.stylex"
import * as stylex from "@stylexjs/stylex"
import type { ComposeStatus } from "./presentation"

export function TypingLine(props: { status: ComposeStatus | undefined }) {
  const status = props.status
  if (!status) return null
  const animated = status.kind !== "working"
  return (
    <span {...stylex.props(styles.line)}>
      {status.text}
      {animated ? (
        <span aria-hidden="true" {...stylex.props(styles.dots)}>
          <span {...stylex.props(styles.dot)}>.</span>
          <span {...stylex.props(styles.dot, styles.dot2)}>.</span>
          <span {...stylex.props(styles.dot, styles.dot3)}>.</span>
        </span>
      ) : null}
    </span>
  )
}

const pulse = stylex.keyframes({
  "0%": { opacity: 0.2 },
  "50%": { opacity: 1 },
  "100%": { opacity: 0.2 },
})

const styles = stylex.create({
  line: {
    color: color.accent,
    fontSize: font.sizeCallout,
    whiteSpace: "nowrap",
    overflow: "hidden",
    textOverflow: "ellipsis",
  },
  dots: { display: "inline-flex" },
  dot: {
    animationName: { default: pulse, "@media (prefers-reduced-motion: reduce)": "none" },
    animationDuration: "1.2s",
    animationIterationCount: "infinite",
  },
  dot2: { animationDelay: "0.2s" },
  dot3: { animationDelay: "0.4s" },
})
