import * as stylex from "@stylexjs/stylex"
import { colors } from "../styles/tokens.stylex"

export function MessageUnreadSeparator() {
  return (
    <div
      role="separator"
      aria-label="Unread messages"
      {...stylex.props(styles.row)}
    >
      <span {...stylex.props(styles.line)} />
      <span {...stylex.props(styles.label)}>Unread messages</span>
      <span {...stylex.props(styles.line)} />
    </div>
  )
}

const styles = stylex.create({
  row: {
    display: "flex",
    alignItems: "center",
    gap: 8,
    paddingBlock: 8,
    paddingInline: 18,
    color: colors.accent,
    fontSize: 10,
    fontWeight: 500,
  },
  line: {
    height: 1,
    flex: 1,
    backgroundColor: colors.accent,
    opacity: 0.32,
  },
  label: {
    flexShrink: 0,
  },
})
