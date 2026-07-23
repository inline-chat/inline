import * as stylex from "@stylexjs/stylex"
import { Icon, type IconName } from "~/ui/Icon"
import { colors } from "../styles/tokens.stylex"

export type SettingsCategory =
  | "account"
  | "appearance"
  | "storage"
  | "about"

const categories: readonly {
  value: SettingsCategory
  label: string
  icon: IconName
}[] = [
  { value: "account", label: "Account", icon: "person" },
  { value: "appearance", label: "Appearance", icon: "eye" },
  { value: "storage", label: "Data & Storage", icon: "sliders" },
  { value: "about", label: "About", icon: "at" },
]

export function SettingsSidebar({
  value,
  onChange,
}: {
  value: SettingsCategory
  onChange: (category: SettingsCategory) => void
}) {
  return (
    <nav aria-label="Settings" {...stylex.props(styles.root)}>
      {categories.map((category) => (
        <button
          key={category.value}
          type="button"
          aria-current={value === category.value ? "page" : undefined}
          onClick={() => onChange(category.value)}
          {...stylex.props(
            styles.row,
            value === category.value && styles.selected,
          )}
        >
          <Icon name={category.icon} size={15} />
          <span>{category.label}</span>
        </button>
      ))}
    </nav>
  )
}

const styles = stylex.create({
  root: {
    minWidth: 0,
    padding: 10,
    backgroundColor: colors.replyPane,
  },
  row: {
    width: "100%",
    height: 32,
    display: "grid",
    gridTemplateColumns: "20px minmax(0, 1fr)",
    alignItems: "center",
    gap: 7,
    paddingInline: 9,
    borderRadius: 8,
    backgroundColor: {
      default: "transparent",
      ":hover": colors.hovered,
    },
    color: colors.textPrimary,
    fontSize: 12,
    textAlign: "left",
    cursor: "pointer",
    ":focus-visible": {
      outlineWidth: 2,
      outlineStyle: "solid",
      outlineColor: colors.accent,
      outlineOffset: 1,
    },
  },
  selected: {
    backgroundColor: colors.selected,
    fontWeight: 500,
  },
})
