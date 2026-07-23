import * as stylex from "@stylexjs/stylex"
import { colors } from "../styles/tokens.stylex"

export function AllChatsSectionHeader({ title }: { title: string }) {
  return <h2 {...stylex.props(styles.title)}>{title}</h2>
}

const styles = stylex.create({
  title: {
    margin: 0,
    paddingBlock: "8px 0",
    paddingInline: 13,
    color: colors.textSecondary,
    fontSize: 12,
    fontWeight: 600,
    lineHeight: 1.2,
  },
})
