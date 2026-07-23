import * as stylex from "@stylexjs/stylex"
import type { InputHTMLAttributes } from "react"
import { colors } from "../styles/tokens.stylex"

export function OnboardingField(props: InputHTMLAttributes<HTMLInputElement>) {
  return <input {...props} {...stylex.props(styles.field)} />
}

const styles = stylex.create({
  field: {
    width: 260,
    height: 34,
    paddingInline: 10,
    borderWidth: 1,
    borderStyle: "solid",
    borderColor: colors.controlOutline,
    borderRadius: 7,
    outline: "none",
    backgroundColor: colors.control,
    color: colors.textPrimary,
    fontSize: 13,
    boxShadow: {
      default: "none",
      ":focus": `0 0 0 3px color-mix(in srgb, ${colors.accent} 22%, transparent)`,
    },
    "::placeholder": {
      color: colors.textTertiary,
    },
  },
})
