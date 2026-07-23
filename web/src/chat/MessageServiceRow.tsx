import * as stylex from "@stylexjs/stylex"
import { colors, metrics } from "../styles/tokens.stylex"

export function MessageServiceRow({ label }: { label: string }) {
  return (
    <div {...stylex.props(styles.root)}>
      <span {...stylex.props(styles.label)}>{label}</span>
    </div>
  )
}

const styles = stylex.create({
  root: {
    width: "100%",
    display: "flex",
    justifyContent: "center",
    paddingBlock: 6,
    paddingInline: metrics.messageSideInset,
  },
  label: {
    maxWidth: 360,
    color: colors.textSecondary,
    fontSize: 10,
    lineHeight: 1.3,
    textAlign: "center",
  },
})
