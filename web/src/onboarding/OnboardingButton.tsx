import * as stylex from "@stylexjs/stylex"
import type { ButtonHTMLAttributes, ReactNode } from "react"
import { colors } from "../styles/tokens.stylex"

export function OnboardingButton({
  children,
  kind = "primary",
  ...props
}: ButtonHTMLAttributes<HTMLButtonElement> & {
  children: ReactNode
  kind?: "primary" | "secondary"
}) {
  return (
    <button
      type="button"
      {...props}
      {...stylex.props(styles.button, kind === "primary" ? styles.primary : styles.secondary)}
    >
      {children}
    </button>
  )
}

const styles = stylex.create({
  button: {
    minWidth: 112,
    height: 34,
    paddingInline: 16,
    borderRadius: 8,
    cursor: "default",
    fontSize: 13,
    fontWeight: 500,
    transition: "background-color 120ms ease, opacity 120ms ease",
    opacity: {
      default: 1,
      ":disabled": 0.5,
    },
  },
  primary: {
    backgroundColor: colors.accent,
    color: "#fff",
    boxShadow: "inset 0 0 0 1px rgba(255,255,255,.15), 0 1px 2px rgba(0,0,0,.14)",
  },
  secondary: {
    width: 238,
    height: 42,
    display: "flex",
    alignItems: "center",
    justifyContent: "flex-start",
    gap: 10,
    backgroundColor: {
      default: colors.control,
      ":hover": colors.controlHover,
    },
    color: colors.textPrimary,
    boxShadow: `inset 0 0 0 1px ${colors.controlOutline}, 0 1px 2px ${colors.shadow}`,
  },
})
