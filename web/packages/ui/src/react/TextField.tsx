import * as stylex from "@stylexjs/stylex"
import { type InputHTMLAttributes, type Ref, useId } from "react"
import { color } from "../tokens/color.stylex"
import { font } from "../tokens/font.stylex"
import { motion } from "../tokens/motion.stylex"
import { radius } from "../tokens/radius.stylex"
import { size } from "../tokens/size.stylex"
import { space } from "../tokens/space.stylex"

export type TextFieldProps = Omit<InputHTMLAttributes<HTMLInputElement>, "style" | "className" | "size"> & {
  label: string
  /** Hide the label visually; it stays the accessible name. */
  hideLabel?: boolean
  description?: string
  error?: string
  /**
   * Marks the field invalid without an inline error, for a feature that shows
   * its error elsewhere (a shared region). Sets `aria-invalid` and the invalid border.
   */
  invalid?: boolean
  /** IDs of elements outside the field that describe it, appended to `aria-describedby`. */
  describedBy?: string
  size?: "small" | "regular" | "large"
  ref?: Ref<HTMLInputElement>
  style?: stylex.StyleXStyles
}

/**
 * A labelled single-line text input. `dir="auto"` so user-written text
 * picks its own direction. Use `onInput` for typing and `onChange` for commits.
 */
export function TextField({
  label,
  hideLabel,
  description,
  error,
  invalid,
  describedBy: externalDescribedBy,
  size: fieldSize = "regular",
  ref,
  style,
  ...rest
}: TextFieldProps) {
  const id = useId()
  const descriptionId = `${id}-description`
  const errorId = `${id}-error`
  const describedBy =
    [description ? descriptionId : null, error ? errorId : null, externalDescribedBy || null].filter(Boolean).join(" ") ||
    undefined
  const isInvalid = !!error || !!invalid
  return (
    <div {...stylex.props(styles.field, style)}>
      <label htmlFor={id} {...stylex.props(styles.label, hideLabel && styles.hidden)}>
        {label}
      </label>
      <input
        id={id}
        dir="auto"
        aria-invalid={isInvalid ? true : undefined}
        aria-describedby={describedBy}
        {...rest}
        ref={ref}
        {...stylex.props(styles.input, sizes[fieldSize], isInvalid && styles.invalid, !!rest.disabled && styles.disabled)}
      />
      {description && (
        <span id={descriptionId} {...stylex.props(styles.description)}>
          {description}
        </span>
      )}
      {error && (
        <span id={errorId} {...stylex.props(styles.error)}>
          {error}
        </span>
      )}
    </div>
  )
}

const styles = stylex.create({
  field: { display: "flex", flexDirection: "column", gap: space.xs, minWidth: 0 },
  label: { fontSize: font.sizeCallout, fontWeight: font.weightMedium, color: color.secondaryLabel },
  hidden: {
    position: "absolute",
    width: "1px",
    height: "1px",
    overflow: "hidden",
    clipPath: "inset(50%)",
    whiteSpace: "nowrap",
  },
  input: {
    boxSizing: "border-box",
    width: "100%",
    minWidth: 0,
    paddingInline: space.md,
    fontFamily: font.familySystem,
    color: color.label,
    backgroundColor: color.textBackground,
    borderWidth: "1px",
    borderStyle: "solid",
    borderColor: color.controlBorder,
    borderRadius: radius.control,
    outline: { default: "none", ":focus-visible": `${size.focusRingWidth} solid ${color.focusRing}` },
    outlineOffset: "0px",
    transitionProperty: "border-color",
    transitionDuration: motion.durationFast,
    "::placeholder": { color: color.placeholderText },
  },
  invalid: { borderColor: color.red },
  disabled: { opacity: 0.5 },
  description: { fontSize: font.sizeCallout, color: color.secondaryLabel },
  error: { fontSize: font.sizeCallout, color: color.red },
})

const sizes = stylex.create({
  small: { height: size.controlSmall, fontSize: font.sizeCallout },
  regular: { height: size.control, fontSize: font.sizeBody },
  large: { height: size.controlLarge, fontSize: font.sizeTitle3 },
})
