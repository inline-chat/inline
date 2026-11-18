import * as stylex from "@stylexjs/stylex"
import { useElement, useModel } from "@inline/reactive/react"
import type { ButtonHTMLAttributes, ReactNode, Ref } from "react"
import { combineParts, type Part } from "../foundations/parts"
import { TooltipController } from "../tooltip/controller"
import { color } from "../tokens/color.stylex"
import { font } from "../tokens/font.stylex"
import { motion } from "../tokens/motion.stylex"
import { radius } from "../tokens/radius.stylex"
import { shadow } from "../tokens/shadow.stylex"
import { size } from "../tokens/size.stylex"
import { space } from "../tokens/space.stylex"
import { shared } from "./styles"
import { TooltipContent } from "./Tooltip"

export type ButtonVariant = "primary" | "secondary" | "plain" | "destructive"
export type ButtonSize = "small" | "regular" | "large"

export type ButtonProps = Omit<ButtonHTMLAttributes<HTMLButtonElement>, "style" | "className"> & {
  variant?: ButtonVariant
  size?: ButtonSize
  /** Shown before the label. */
  icon?: ReactNode
  ref?: Ref<HTMLButtonElement>
  style?: stylex.StyleXStyles
}

/** A push button. Defaults to `type="button"` so it never submits a form by accident. */
export function Button({ variant = "secondary", size: buttonSize = "regular", icon, children, style, ref, ...rest }: ButtonProps) {
  return (
    <button
      type="button"
      {...rest}
      ref={ref}
      {...stylex.props(
        styles.base,
        shared.focusRing,
        sizes[buttonSize],
        variants[variant],
        rest.disabled && styles.disabled,
        style,
      )}
    >
      {icon}
      {children}
    </button>
  )
}

export type IconButtonProps = Omit<ButtonProps, "children" | "icon" | "variant" | "part"> & {
  /** The accessible name, also shown as the tooltip. */
  label: string
  icon: ReactNode
  /** Another controller part for the same button, e.g. a menu trigger. */
  part?: Part
  /** Pressed state for toolbar toggles. */
  pressed?: boolean
  /** A shortcut hint shown in the tooltip after the label ("⌘K"), hidden from assistive technology. */
  shortcut?: string
  /**
   * `aria-keyshortcuts` for it ("Meta+K"): `ariaKeyShortcuts(combo)`. Not
   * derived from `shortcut` here, to keep the hint parser off the first frame.
   */
  keyshortcuts?: string
}

/** A square icon-only button with a tooltip that is its accessible name. */
export function IconButton({ label, icon, part, pressed, shortcut, keyshortcuts, size: buttonSize = "regular", style, ...rest }: IconButtonProps) {
  const tooltip = useModel(() => new TooltipController())
  const combined = useModel(() => (part ? combineParts(tooltip.trigger, part) : tooltip.trigger), [part])
  const ref = useElement(combined)
  return (
    <>
      <button
        type="button"
        aria-label={label}
        aria-pressed={pressed}
        aria-keyshortcuts={keyshortcuts}
        {...rest}
        ref={ref}
        {...stylex.props(
          styles.base,
          shared.focusRing,
          iconSizes[buttonSize],
          variants.plain,
          pressed && styles.pressed,
          rest.disabled && styles.disabled,
          style,
        )}
      >
        {icon}
      </button>
      <TooltipContent controller={tooltip}>
        {label}
        {shortcut && (
          <span aria-hidden="true" {...stylex.props(styles.tooltipShortcut)}>
            {shortcut}
          </span>
        )}
      </TooltipContent>
    </>
  )
}

const styles = stylex.create({
  tooltipShortcut: { marginInlineStart: space.md, color: color.secondaryLabel, letterSpacing: "0.04em" },
  base: {
    display: "inline-flex",
    alignItems: "center",
    justifyContent: "center",
    gap: space.sm,
    boxSizing: "border-box",
    borderStyle: "none",
    borderRadius: radius.control,
    fontFamily: font.familySystem,
    fontWeight: font.weightRegular,
    lineHeight: 1,
    whiteSpace: "nowrap",
    cursor: "default",
    userSelect: "none",
    transitionProperty: "background-color, box-shadow, color",
    transitionDuration: motion.durationFast,
    transitionTimingFunction: motion.easeStandard,
    WebkitTapHighlightColor: "transparent",
  },
  pressed: {
    backgroundColor: color.controlPressed,
    color: color.accent,
  },
  disabled: {
    opacity: 0.45,
    pointerEvents: "none",
  },
})

const sizes = stylex.create({
  small: { height: size.controlSmall, paddingInline: space.md, fontSize: font.sizeCallout },
  regular: { height: size.control, paddingInline: space.lg, fontSize: font.sizeBody },
  large: { height: size.controlLarge, paddingInline: space.xl, fontSize: font.sizeTitle3 },
})

const iconSizes = stylex.create({
  small: { width: size.controlSmall, height: size.controlSmall, padding: 0 },
  regular: { width: size.control, height: size.control, padding: 0 },
  large: { width: size.controlLarge, height: size.controlLarge, padding: 0 },
})

const variants = stylex.create({
  primary: {
    backgroundColor: { default: color.accent, ":hover": color.accentHover, ":active": color.accentPressed },
    color: color.onAccent,
    fontWeight: font.weightMedium,
  },
  secondary: {
    backgroundColor: { default: color.control, ":active": color.controlPressed },
    color: color.controlText,
    boxShadow: shadow.control,
  },
  plain: {
    backgroundColor: { default: "transparent", ":hover": color.controlHover, ":active": color.controlPressed },
    color: color.controlText,
  },
  destructive: {
    backgroundColor: { default: color.destructive, ":active": color.red },
    color: color.onAccent,
    fontWeight: font.weightMedium,
  },
})
