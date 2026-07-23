import * as stylex from "@stylexjs/stylex"
import type { ReactNode } from "react"
import { colors, metrics } from "../styles/tokens.stylex"
import { Icon, type IconName } from "~/ui/Icon"

export function SidebarActionRow({
  icon,
  title,
  selected,
  accessory,
  onClick,
}: {
  icon: IconName
  title: string
  selected?: boolean
  accessory?: ReactNode
  onClick: () => void
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      {...stylex.props(styles.row, selected && styles.selected)}
    >
      <span {...stylex.props(styles.icon)}>
        <Icon name={icon} size={17} />
      </span>
      <span {...stylex.props(styles.title)}>{title}</span>
      {accessory}
    </button>
  )
}

const styles = stylex.create({
  row: {
    width: `calc(100% - ${metrics.sidebarOuterInset} * 2)`,
    height: 34,
    display: "grid",
    gridTemplateColumns: "24px minmax(0, 1fr) auto",
    alignItems: "center",
    gap: 8,
    marginInline: metrics.sidebarOuterInset,
    paddingInline: metrics.sidebarInnerInset,
    borderRadius: metrics.sidebarRadius,
    backgroundColor: {
      default: "transparent",
      ":hover": colors.hovered,
    },
    color: colors.textPrimary,
    fontSize: 13,
    textAlign: "left",
  },
  selected: {
    backgroundColor: colors.selected,
  },
  icon: {
    width: 24,
    display: "grid",
    placeItems: "center",
    color: colors.textSecondary,
  },
  title: {
    overflow: "hidden",
    textOverflow: "ellipsis",
    whiteSpace: "nowrap",
  },
})
