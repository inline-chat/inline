import * as stylex from "@stylexjs/stylex"
import { colors } from "../styles/tokens.stylex"

export function InlineSegmentedControl<T extends string>({
  label,
  value,
  options,
  onChange,
}: {
  label: string
  value: T
  options: readonly { value: T; label: string }[]
  onChange: (value: T) => void
}) {
  return (
    <div
      role="radiogroup"
      aria-label={label}
      {...stylex.props(styles.root)}
    >
      {options.map((option) => (
        <button
          key={option.value}
          type="button"
          role="radio"
          aria-checked={option.value === value}
          onClick={() => onChange(option.value)}
          {...stylex.props(
            styles.option,
            option.value === value && styles.selected,
          )}
        >
          {option.label}
        </button>
      ))}
    </div>
  )
}

const styles = stylex.create({
  root: {
    minWidth: 180,
    height: 28,
    display: "grid",
    gridAutoColumns: "minmax(0, 1fr)",
    gridAutoFlow: "column",
    gap: 1,
    padding: 2,
    borderRadius: 8,
    backgroundColor: "light-dark(rgba(0,0,0,.065), rgba(255,255,255,.07))",
  },
  option: {
    minWidth: 0,
    paddingInline: 9,
    borderRadius: 6,
    backgroundColor: "transparent",
    color: colors.textSecondary,
    fontSize: 11,
    cursor: "pointer",
    ":focus-visible": {
      outlineWidth: 2,
      outlineStyle: "solid",
      outlineColor: colors.accent,
      outlineOffset: 1,
    },
  },
  selected: {
    backgroundColor: colors.content,
    color: colors.textPrimary,
    boxShadow: "0 1px 2px rgba(0,0,0,.13)",
  },
})
