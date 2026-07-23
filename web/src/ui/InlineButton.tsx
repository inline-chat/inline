import * as stylex from "@stylexjs/stylex"
import { forwardRef, type ButtonHTMLAttributes } from "react"
import { colors } from "../styles/tokens.stylex"

export type InlineButtonVariant =
  | "primary"
  | "secondary"
  | "plain"
  | "destructive"

export const InlineButton = forwardRef<
  HTMLButtonElement,
  ButtonHTMLAttributes<HTMLButtonElement> & {
    variant?: InlineButtonVariant
    size?: "small" | "regular"
  }
>(function InlineButton(
  {
    variant = "secondary",
    size = "regular",
    type = "button",
    ...props
  },
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
        variant === "primary" && styles.primary,
        variant === "secondary" && styles.secondary,
        variant === "plain" && styles.plain,
        variant === "destructive" && styles.destructive,
      )}
    />
  )
})

const styles = stylex.create({
  root: {
    minWidth: 0,
    height: 30,
    display: "inline-flex",
    alignItems: "center",
    justifyContent: "center",
    gap: 6,
    paddingInline: 12,
    borderRadius: 7,
    fontSize: 13,
    fontWeight: 500,
    lineHeight: 1,
    cursor: "pointer",
    transitionProperty: "background-color, color, opacity",
    transitionDuration: "120ms",
    ":focus-visible": {
      outlineWidth: 2,
      outlineStyle: "solid",
      outlineColor: colors.accent,
      outlineOffset: 2,
    },
    ":disabled": {
      cursor: "default",
      opacity: 0.45,
    },
  },
  small: {
    height: 26,
    paddingInline: 9,
    fontSize: 12,
  },
  primary: {
    backgroundColor: {
      default: colors.accent,
      ":hover": "light-dark(rgb(111, 79, 216), rgb(166, 143, 244))",
    },
    color: "#fff",
  },
  secondary: {
    backgroundColor: {
      default: colors.control,
      ":hover": colors.controlHover,
    },
    color: colors.textPrimary,
    boxShadow: `inset 0 0 0 1px ${colors.controlOutline}`,
  },
  plain: {
    backgroundColor: {
      default: "transparent",
      ":hover": colors.hovered,
    },
    color: colors.textPrimary,
  },
  destructive: {
    backgroundColor: {
      default: colors.control,
      ":hover": colors.controlHover,
    },
    color: colors.destructive,
    boxShadow: `inset 0 0 0 1px ${colors.controlOutline}`,
  },
})
