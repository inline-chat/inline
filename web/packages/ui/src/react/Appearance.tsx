/**
 * Appearance views: scopes that apply a theme to a subtree, and the settings
 * controls (appearance switch, theme swatches, text size stepper, and a
 * segmented control for the other choices). They render controller state and
 * call its setters; no effects. The document root is bound outside React by
 * `startDocumentAppearance()` (see src/theme/README.md).
 */

import * as stylex from "@stylexjs/stylex"
import { useElement, useSignal } from "@inline/reactive/react"
import { type ReactNode, useId } from "react"
import { THEME_IDS, THEME_TITLES, type ThemeId } from "../theme/catalog"
import type { AppearanceController } from "../theme/controller"
import {
  type Appearance,
  LINE_SPACING_STEPS,
  lineSpacingTitle,
  type MessageFont,
  type SidebarItemSize,
} from "../theme/settings"
import { themeScopeClassName } from "../theme/stylex-binding"
import { color } from "../tokens/color.stylex"
import { font } from "../tokens/font.stylex"
import { motion } from "../tokens/motion.stylex"
import { radius } from "../tokens/radius.stylex"
import { size } from "../tokens/size.stylex"
import { space } from "../tokens/space.stylex"
import { Button } from "./Button"

/** A subtree with the controller's live settings applied (a settings preview). */
export function AppearanceScope(props: { controller: AppearanceController; children: ReactNode }) {
  return (
    <div ref={useElement<HTMLDivElement>(props.controller)} {...stylex.props(styles.scope)}>
      {props.children}
    </div>
  )
}

/** A subtree with a fixed theme and appearance, whatever the document uses. */
export function ThemeScope(props: { theme: ThemeId; appearance: Appearance; children: ReactNode; style?: stylex.StyleXStyles }) {
  const scoped = stylex.props(styles.scope, props.style)
  return (
    <div
      data-theme={props.theme}
      data-appearance={props.appearance}
      className={[scoped.className, themeScopeClassName(props.theme, props.appearance)].filter(Boolean).join(" ")}
      style={scoped.style}
    >
      {props.children}
    </div>
  )
}

export type SegmentOption<T extends string | number> = { value: T; label: string }

/**
 * One choice among a few, as a native radio group styled as a segmented
 * control: arrow keys, labels and form semantics come from the platform.
 */
export function SegmentedControl<T extends string | number>(props: {
  label: string
  options: readonly SegmentOption<T>[]
  value: T
  onChange: (value: T) => void
}) {
  const name = useId()
  return (
    <div role="radiogroup" aria-label={props.label} {...stylex.props(styles.segmented)}>
      {props.options.map((option) => {
        const checked = option.value === props.value
        return (
          <label key={String(option.value)} {...stylex.props(styles.segment, checked && styles.segmentChecked)}>
            <input
              type="radio"
              name={name}
              checked={checked}
              onChange={() => props.onChange(option.value)}
              {...stylex.props(styles.radio)}
            />
            {option.label}
          </label>
        )
      })}
    </div>
  )
}

const APPEARANCE_OPTIONS: readonly SegmentOption<Appearance>[] = [
  { value: "light", label: "Light" },
  { value: "dark", label: "Dark" },
  { value: "system", label: "Auto" },
]

/** Light, Dark, Auto, in the Mac app's order. */
export function AppearanceSwitch(props: { controller: AppearanceController }) {
  return (
    <SegmentedControl
      label="Appearance"
      options={APPEARANCE_OPTIONS}
      value={useSignal(props.controller.appearance)}
      onChange={(value) => props.controller.setAppearance(value)}
    />
  )
}

/** Every theme as a swatch drawn with its own tokens, in the appearance in effect. */
export function ThemeSwatchGrid(props: { controller: AppearanceController }) {
  const selected = useSignal(props.controller.theme)
  const appearance = useSignal(props.controller.resolvedAppearance)
  const name = useId()
  return (
    <div role="radiogroup" aria-label="Theme" {...stylex.props(styles.swatchGrid)}>
      {THEME_IDS.map((theme) => (
        <label key={theme} {...stylex.props(styles.swatchItem)}>
          <input
            type="radio"
            name={name}
            checked={theme === selected}
            onChange={() => props.controller.setTheme(theme)}
            {...stylex.props(styles.radio)}
          />
          <ThemeScope theme={theme} appearance={appearance} style={[styles.swatch, theme === selected && styles.swatchSelected]}>
            <span {...stylex.props(styles.swatchSidebar)} />
            <span {...stylex.props(styles.swatchBubbles)}>
              <span {...stylex.props(styles.swatchOther)} />
              <span {...stylex.props(styles.swatchOwn)} />
            </span>
          </ThemeScope>
          <span {...stylex.props(styles.swatchTitle)}>{THEME_TITLES[theme]}</span>
        </label>
      ))}
    </div>
  )
}

/** Smaller, the size, bigger, and reset: the View menu's text size commands. */
export function TextSizeStepper(props: { controller: AppearanceController }) {
  const { controller } = props
  const textSize = useSignal(controller.textSize)
  return (
    <div role="group" aria-label="Message text size" {...stylex.props(styles.stepper)}>
      <Button
        size="small"
        aria-label="Make Text Smaller"
        disabled={!useSignal(controller.canDecreaseTextSize)}
        onClick={() => controller.decreaseTextSize()}
      >
        <span aria-hidden="true" {...stylex.props(styles.smallA)}>
          A
        </span>
      </Button>
      <output aria-live="polite" {...stylex.props(styles.stepperValue)}>
        {textSize} pt
      </output>
      <Button
        size="small"
        aria-label="Make Text Bigger"
        disabled={!useSignal(controller.canIncreaseTextSize)}
        onClick={() => controller.increaseTextSize()}
      >
        <span aria-hidden="true" {...stylex.props(styles.largeA)}>
          A
        </span>
      </Button>
      <Button
        size="small"
        variant="plain"
        disabled={useSignal(controller.isDefaultTextSize)}
        onClick={() => controller.resetTextSize()}
      >
        Normal Size
      </Button>
    </div>
  )
}

const LINE_SPACING_OPTIONS = LINE_SPACING_STEPS.map((value) => ({ value, label: lineSpacingTitle(value) }))
const SIDEBAR_OPTIONS: readonly SegmentOption<SidebarItemSize>[] = [
  { value: "compact", label: "Compact" },
  { value: "standard", label: "Standard" },
]
const FONT_OPTIONS: readonly SegmentOption<MessageFont>[] = [
  { value: "system", label: "System" },
  { value: "monospace", label: "Monospace" },
]

export function LineSpacingControl(props: { controller: AppearanceController }) {
  const value = useSignal(props.controller.lineSpacing)
  const options = LINE_SPACING_OPTIONS.some((o) => o.value === value)
    ? LINE_SPACING_OPTIONS
    : [...LINE_SPACING_OPTIONS, { value, label: lineSpacingTitle(value) }].sort((a, b) => a.value - b.value)
  return (
    <SegmentedControl
      label="Line spacing"
      options={options}
      value={value}
      onChange={(next) => props.controller.setLineSpacing(next)}
    />
  )
}

export function SidebarItemSizeControl(props: { controller: AppearanceController }) {
  return (
    <SegmentedControl
      label="Sidebar item size"
      options={SIDEBAR_OPTIONS}
      value={useSignal(props.controller.sidebarItemSize)}
      onChange={(value) => props.controller.setSidebarItemSize(value)}
    />
  )
}

export function MessageFontControl(props: { controller: AppearanceController }) {
  return (
    <SegmentedControl
      label="Message font"
      options={FONT_OPTIONS}
      value={useSignal(props.controller.messageFont)}
      onChange={(value) => props.controller.setMessageFont(value)}
    />
  )
}

const styles = stylex.create({
  scope: { color: color.label, backgroundColor: color.windowBackground },
  segmented: {
    display: "inline-flex",
    padding: "2px",
    gap: "2px",
    borderRadius: radius.control,
    backgroundColor: color.controlTrack,
  },
  segment: {
    position: "relative",
    display: "inline-flex",
    alignItems: "center",
    justifyContent: "center",
    minHeight: size.controlSmall,
    paddingInline: space.md,
    borderRadius: radius.small,
    fontFamily: font.familySystem,
    fontSize: font.sizeCallout,
    color: color.controlText,
    cursor: "default",
    userSelect: "none",
    transitionProperty: "background-color",
    transitionDuration: motion.durationFast,
    backgroundColor: { default: "transparent", ":hover": color.controlHover },
    outline: { default: "none", ":has(:focus-visible)": `${size.focusRingWidth} solid ${color.focusRing}` },
  },
  segmentChecked: {
    backgroundColor: { default: color.control, ":hover": color.control },
    boxShadow: `0 0 0 0.5px ${color.controlBorder}`,
  },
  // The native radio stays in the tree for keyboard and assistive technology; the label is its visual.
  radio: {
    position: "absolute",
    inset: 0,
    margin: 0,
    opacity: 0,
    cursor: "default",
  },
  swatchGrid: {
    display: "grid",
    gridTemplateColumns: "repeat(auto-fill, minmax(84px, 1fr))",
    gap: space.lg,
  },
  swatchItem: {
    position: "relative",
    display: "flex",
    flexDirection: "column",
    alignItems: "center",
    gap: space.xs,
    fontSize: font.sizeCallout,
    color: color.label,
    borderRadius: radius.control,
    outline: { default: "none", ":has(:focus-visible)": `${size.focusRingWidth} solid ${color.focusRing}` },
    outlineOffset: "2px",
  },
  swatch: {
    display: "flex",
    width: "100%",
    height: "52px",
    overflow: "hidden",
    borderRadius: radius.control,
    boxShadow: `0 0 0 1px ${color.separator}`,
  },
  swatchSelected: { boxShadow: `0 0 0 2px ${color.accent}` },
  swatchSidebar: { width: "28%", backgroundColor: color.sidebarBackground },
  swatchBubbles: {
    display: "flex",
    flexDirection: "column",
    justifyContent: "center",
    gap: "4px",
    flexGrow: 1,
    paddingInline: "6px",
  },
  swatchOther: { width: "60%", height: "9px", borderRadius: radius.pill, backgroundColor: color.secondaryBubble },
  swatchOwn: {
    width: "55%",
    height: "9px",
    marginInlineStart: "auto",
    borderRadius: radius.pill,
    backgroundColor: color.bubble,
  },
  swatchTitle: { color: color.secondaryLabel },
  stepper: { display: "inline-flex", alignItems: "center", gap: space.sm },
  stepperValue: {
    minWidth: "44px",
    textAlign: "center",
    fontSize: font.sizeCallout,
    fontVariantNumeric: "tabular-nums",
    color: color.secondaryLabel,
  },
  smallA: { fontSize: "10px", fontWeight: font.weightSemibold },
  largeA: { fontSize: "15px", fontWeight: font.weightSemibold },
})
