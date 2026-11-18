import * as stylex from "@stylexjs/stylex"
import { useElement } from "@inline/reactive/react"
import type { ReactNode } from "react"
import type { TooltipController } from "../tooltip/controller"
import { color } from "../tokens/color.stylex"
import { font } from "../tokens/font.stylex"
import { motion } from "../tokens/motion.stylex"
import { radius } from "../tokens/radius.stylex"
import { shadow } from "../tokens/shadow.stylex"
import { space } from "../tokens/space.stylex"
import { shared } from "./styles"

/**
 * The tooltip bubble. Always rendered (hidden as a popover) so the trigger's
 * `aria-describedby` points at real text. Attach `controller.trigger` to the
 * element it describes.
 */
export function TooltipContent(props: { controller: TooltipController; children: ReactNode }) {
  const ref = useElement(props.controller.content)
  return (
    <div ref={ref} popover="manual" {...stylex.props(shared.layerReset, styles.tooltip)}>
      {props.children}
    </div>
  )
}

const fadeIn = stylex.keyframes({
  from: { opacity: 0 },
  to: { opacity: 1 },
})

const styles = stylex.create({
  tooltip: {
    maxWidth: "280px",
    paddingBlock: space.xs,
    paddingInline: space.md,
    backgroundColor: color.tooltipBackground,
    color: color.label,
    fontSize: font.sizeCallout,
    lineHeight: font.lineHeightTight,
    borderRadius: radius.control,
    boxShadow: shadow.menu,
    pointerEvents: "none",
    animationName: fadeIn,
    animationDuration: motion.durationFast,
    animationTimingFunction: motion.easeOut,
  },
})
