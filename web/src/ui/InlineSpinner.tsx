import * as stylex from "@stylexjs/stylex"
import { colors } from "../styles/tokens.stylex"

export function InlineSpinner({ label = "Loading" }: { label?: string }) {
  return (
    <span role="status" aria-label={label} {...stylex.props(styles.root)} />
  )
}

const styles = stylex.create({
  root: {
    width: 14,
    height: 14,
    display: "inline-block",
    borderWidth: 2,
    borderStyle: "solid",
    borderColor: colors.controlOutline,
    borderTopColor: colors.textSecondary,
    borderRadius: "50%",
    animationName: stylex.keyframes({ to: { transform: "rotate(360deg)" } }),
    animationDuration: "0.8s",
    animationTimingFunction: "linear",
    animationIterationCount: "infinite",
  },
})
