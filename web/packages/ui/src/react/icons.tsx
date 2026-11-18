/**
 * The few glyphs the primitives need, as inline SVG in `currentColor`.
 * Icons beyond these are the app's choice; this file is not an icon set.
 */

import * as stylex from "@stylexjs/stylex"
import type { ReactNode } from "react"

type IconProps = { size?: number; style?: stylex.StyleXStyles }

const Svg = (props: IconProps & { children: ReactNode }) => (
  <svg
    width={props.size ?? 16}
    height={props.size ?? 16}
    viewBox="0 0 16 16"
    fill="none"
    stroke="currentColor"
    strokeWidth={1.6}
    strokeLinecap="round"
    strokeLinejoin="round"
    aria-hidden="true"
    focusable="false"
    {...stylex.props(styles.icon, props.style)}
  >
    {props.children}
  </svg>
)

export const CheckIcon = (props: IconProps) => (
  <Svg {...props}>
    <path d="M3.5 8.5l3 3 6-7" />
  </Svg>
)

/** Points to the inline end; mirrored in right to left. */
export const ChevronIcon = (props: IconProps) => (
  <Svg {...props} style={[styles.mirror, props.style]}>
    <path d="M6 3.5L10.5 8 6 12.5" />
  </Svg>
)

export const ChevronDownIcon = (props: IconProps) => (
  <Svg {...props}>
    <path d="M3.5 6l4.5 4.5L12.5 6" />
  </Svg>
)

export const CloseIcon = (props: IconProps) => (
  <Svg {...props}>
    <path d="M4 4l8 8M12 4l-8 8" />
  </Svg>
)

export const DotIcon = (props: IconProps) => (
  <Svg {...props}>
    <circle cx="8" cy="8" r="2.5" fill="currentColor" stroke="none" />
  </Svg>
)

const styles = stylex.create({
  icon: { flexShrink: 0, display: "block" },
  mirror: { transform: { default: null, ":dir(rtl)": "scaleX(-1)" } },
})
