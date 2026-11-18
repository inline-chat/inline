/**
 * The sign-in screen's text field. Like the UI kit's `TextField`, but its
 * error lives in the step's shared message region (one place on every step,
 * announced politely), so the field points at that region by ID instead of
 * rendering its own error text.
 */

import { color } from "@inline/ui/tokens/color.stylex"
import { font } from "@inline/ui/tokens/font.stylex"
import { motion } from "@inline/ui/tokens/motion.stylex"
import { radius } from "@inline/ui/tokens/radius.stylex"
import { size } from "@inline/ui/tokens/size.stylex"
import { space } from "@inline/ui/tokens/space.stylex"
import * as stylex from "@stylexjs/stylex"
import { type InputHTMLAttributes, type Ref, useId } from "react"

export type FieldProps = Omit<InputHTMLAttributes<HTMLInputElement>, "style" | "className" | "size"> & {
  label: string
  /** Short help under the field, read as part of its description. */
  hint?: string
  /** The ID of the step's message region; the field is described by it while invalid. */
  messageId: string
  invalid: boolean
  /** `code` centers the digits and spaces them out. */
  variant?: "text" | "code"
  ref?: Ref<HTMLInputElement>
}

export function Field({ label, hint, messageId, invalid, variant = "text", ref, ...rest }: FieldProps) {
  const id = useId()
  const hintId = `${id}-hint`
  const describedBy = [hint ? hintId : null, invalid ? messageId : null].filter(Boolean).join(" ") || undefined
  return (
    <div {...stylex.props(styles.field)}>
      <label htmlFor={id} {...stylex.props(styles.label)}>
        {label}
      </label>
      <input
        id={id}
        dir="auto"
        {...rest}
        aria-invalid={invalid || undefined}
        aria-describedby={describedBy}
        ref={ref}
        {...stylex.props(
          styles.input,
          variant === "code" && styles.code,
          invalid && styles.invalid,
          rest.readOnly && styles.busy,
        )}
      />
      {hint && (
        <span id={hintId} {...stylex.props(styles.hint)}>
          {hint}
        </span>
      )}
    </div>
  )
}

const styles = stylex.create({
  field: { display: "flex", flexDirection: "column", gap: space.xs, minWidth: 0 },
  label: { fontSize: font.sizeCallout, fontWeight: font.weightMedium, color: color.secondaryLabel },
  input: {
    boxSizing: "border-box",
    inlineSize: "100%",
    minWidth: 0,
    blockSize: size.controlLarge,
    paddingInline: space.lg,
    fontFamily: font.familySystem,
    fontSize: font.sizeTitle3,
    color: color.label,
    backgroundColor: color.textBackground,
    borderWidth: "1px",
    borderStyle: "solid",
    borderColor: color.controlBorder,
    borderRadius: radius.control,
    outline: { default: "none", ":focus-visible": `${size.focusRingWidth} solid ${color.focusRing}` },
    outlineOffset: "0px",
    transitionProperty: "border-color, opacity",
    transitionDuration: motion.durationFast,
    "::placeholder": { color: color.placeholderText },
  },
  code: {
    fontSize: font.sizeTitle2,
    fontVariantNumeric: "tabular-nums",
    letterSpacing: "0.3em",
    textAlign: "center",
    // Center the digits optically: letter spacing adds space after the last one.
    textIndent: "0.3em",
  },
  invalid: { borderColor: color.red },
  busy: { opacity: 0.7 },
  hint: { fontSize: font.sizeCallout, color: color.secondaryLabel },
})
