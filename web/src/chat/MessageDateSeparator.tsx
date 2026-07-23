import * as stylex from "@stylexjs/stylex"
import { colors } from "../styles/tokens.stylex"

const dayLabel = (date: number) => {
  const value = new Date(date * 1_000)
  const today = new Date()
  if (value.toDateString() === today.toDateString()) return "Today"
  return new Intl.DateTimeFormat(undefined, {
    month: "short",
    day: "numeric",
    year: value.getFullYear() === today.getFullYear() ? undefined : "numeric",
  }).format(value)
}

export function MessageDateSeparator({ date }: { date: number }) {
  return (
    <div role="separator" aria-label={dayLabel(date)} {...stylex.props(styles.root)}>
      <span {...stylex.props(styles.label)}>{dayLabel(date)}</span>
    </div>
  )
}

const styles = stylex.create({
  root: {
    width: "100%",
    display: "flex",
    justifyContent: "center",
    paddingBlock: "10px 5px",
  },
  label: {
    paddingBlock: 3,
    paddingInline: 8,
    borderRadius: 10,
    backgroundColor: "light-dark(rgba(0,0,0,.05), rgba(255,255,255,.07))",
    color: colors.textSecondary,
    fontSize: 9,
    fontWeight: 500,
  },
})
