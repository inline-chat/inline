import * as React from "react"
import * as stylex from "@stylexjs/stylex"
import { colors } from "~/theme/tokens.stylex"

type LargeTextFieldProps = React.InputHTMLAttributes<HTMLInputElement>

export const LargeTextField = React.forwardRef<HTMLInputElement, LargeTextFieldProps>(
  ({ type = "text", ...props }, ref) => {
    return <input ref={ref} type={type} {...stylex.props(styles.input)} {...props} />
  },
)

LargeTextField.displayName = "LargeTextField"

const styles = stylex.create({
  input: {
    width: "100%",
    maxWidth: 420,
    height: 44,
    borderRadius: 12,
    border: `1px solid ${colors.lineColor}`,
    paddingLeft: 14,
    paddingRight: 14,
    fontSize: 16,
    color: colors.primaryText,
    backgroundColor: colors.primaryBg,
    transitionProperty: "border-color, box-shadow, transform",
    transitionDuration: "120ms",

    ":focus-visible": {
      outline: "none",
      borderColor: colors.accent,
      boxShadow: `0 0 0 3px rgba(0, 0, 0, 0.06)`,
      transform: "translateY(-1px)",
    },
  },
})
