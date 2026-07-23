import * as stylex from "@stylexjs/stylex"
import { forwardRef, type InputHTMLAttributes } from "react"
import { colors } from "../styles/tokens.stylex"

export const InlineTextInput = forwardRef<
  HTMLInputElement,
  InputHTMLAttributes<HTMLInputElement>
>(function InlineTextInput(props, ref) {
  return (
    <input
      ref={ref}
      {...props}
      {...stylex.props(styles.input)}
    />
  )
})

const styles = stylex.create({
  input: {
    width: "100%",
    height: 32,
    paddingInline: 10,
    borderWidth: 1,
    borderStyle: "solid",
    borderColor: colors.controlOutline,
    borderRadius: 8,
    backgroundColor: colors.control,
    color: colors.textPrimary,
    fontSize: 13,
    outline: "none",
    ":focus": {
      borderColor: colors.accent,
      boxShadow: "0 0 0 2px light-dark(rgba(123,91,228,.15), rgba(155,130,239,.18))",
    },
    "::placeholder": {
      color: colors.textTertiary,
    },
  },
})
