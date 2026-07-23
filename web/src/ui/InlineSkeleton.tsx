import * as stylex from "@stylexjs/stylex"
import type { CSSProperties } from "react"
import { colors } from "../styles/tokens.stylex"

export function InlineSkeleton({
  width,
  height,
  radius,
  label,
}: {
  width: CSSProperties["width"]
  height: CSSProperties["height"]
  radius?: CSSProperties["borderRadius"]
  label?: string
}) {
  return (
    <span
      aria-label={label}
      aria-hidden={label ? undefined : true}
      style={{ width, height, borderRadius: radius }}
      {...stylex.props(styles.root)}
    />
  )
}

const styles = stylex.create({
  root: {
    display: "block",
    flexShrink: 0,
    backgroundColor: colors.skeleton,
  },
})
