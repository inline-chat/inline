import * as stylex from "@stylexjs/stylex"
import { forwardRef, type ButtonHTMLAttributes } from "react"
import { colors } from "../styles/tokens.stylex"

export const InlineIconButton = forwardRef<
  HTMLButtonElement,
  ButtonHTMLAttributes<HTMLButtonElement> & {
    size?: "small" | "regular"
    selected?: boolean
  }
>(function InlineIconButton(
  { size = "regular", selected, type = "button", ...props },
  ref,
) {
  return (
    <button
      ref={ref}
      type={type}
      {...props}
      {...stylex.props(
        styles.root,
        size === "small" && styles.small,
        selected && styles.selected,
      )}
    />
  )
})

const styles = stylex.create({
  root: {
    width: 28,
    height: 28,
    display: "inline-grid",
    placeItems: "center",
    flexShrink: 0,
    padding: 0,
    borderRadius: 7,
    backgroundColor: {
      default: "transparent",
      ":hover": colors.hovered,
    },
    color: colors.textSecondary,
    cursor: "pointer",
    ":focus-visible": {
      outlineWidth: 2,
      outlineStyle: "solid",
      outlineColor: colors.accent,
      outlineOffset: 1,
    },
    ":disabled": {
      cursor: "default",
      opacity: 0.4,
    },
  },
  small: {
    width: 26,
    height: 26,
  },
  selected: {
    backgroundColor: colors.selected,
    color: colors.textPrimary,
  },
})
