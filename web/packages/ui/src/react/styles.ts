/**
 * Styles shared by several views. Tokens only, logical properties only,
 * focus rings only for keyboard focus.
 */

import * as stylex from "@stylexjs/stylex"
import { color } from "../tokens/color.stylex"
import { font } from "../tokens/font.stylex"
import { motion } from "../tokens/motion.stylex"
import { radius } from "../tokens/radius.stylex"
import { shadow } from "../tokens/shadow.stylex"
import { size } from "../tokens/size.stylex"
import { space } from "../tokens/space.stylex"

// Keyframes are file-local in StyleX; views that animate declare their own.
const layerIn = stylex.keyframes({
  from: { opacity: 0, transform: "scale(0.98)" },
  to: { opacity: 1, transform: "scale(1)" },
})

export const shared = stylex.create({
  /** A keyboard focus ring; pointer focus shows none. */
  focusRing: {
    outline: {
      default: "none",
      ":focus-visible": `${size.focusRingWidth} solid ${color.focusRing}`,
    },
    outlineOffset: "1px",
  },
  /** Reset for a popover or dialog element, before our own surface styles. */
  layerReset: {
    margin: 0,
    padding: 0,
    borderStyle: "none",
    color: color.label,
    fontFamily: font.familySystem,
    fontSize: font.sizeBody,
    lineHeight: font.lineHeightBody,
    overflow: "visible",
  },
  menuSurface: {
    minWidth: size.menuMinWidth,
    maxWidth: "min(360px, var(--ui-available-width, 100vw))",
    maxHeight: "var(--ui-available-height, 70vh)",
    overflowY: "auto",
    padding: "5px",
    boxSizing: "border-box",
    backgroundColor: color.menuBackground,
    backdropFilter: "blur(24px) saturate(1.6)",
    borderRadius: radius.menu,
    boxShadow: shadow.menu,
    outline: "none",
    userSelect: "none",
    animationName: layerIn,
    animationDuration: motion.durationFast,
    animationTimingFunction: motion.easeOut,
  },
  separator: {
    height: "1px",
    marginBlock: space.xs,
    marginInline: space.md,
    backgroundColor: color.separator,
  },
  visuallyHidden: {
    position: "absolute",
    width: "1px",
    height: "1px",
    overflow: "hidden",
    clipPath: "inset(50%)",
    whiteSpace: "nowrap",
  },
})
