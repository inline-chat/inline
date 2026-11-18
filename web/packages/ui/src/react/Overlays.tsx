/** Views for Popover and Dialog (and Sheet). */

import * as stylex from "@stylexjs/stylex"
import { useElement } from "@inline/reactive/react"
import type { ReactNode } from "react"
import type { DialogController } from "../dialog/controller"
import type { PopoverController } from "../popover/controller"
import { color } from "../tokens/color.stylex"
import { font } from "../tokens/font.stylex"
import { motion } from "../tokens/motion.stylex"
import { radius } from "../tokens/radius.stylex"
import { shadow } from "../tokens/shadow.stylex"
import { space } from "../tokens/space.stylex"
import { IconButton } from "./Button"
import { CloseIcon } from "./icons"
import { shared } from "./styles"

/**
 * Popover content. Rendered always (hidden as a popover until open) so focus
 * can move into it the moment it opens. Attach `controller.trigger` to the
 * button that opens it. Pass `arrow` to draw an arrow toward the anchor.
 */
export function PopoverContent(props: { controller: PopoverController; children: ReactNode; arrow?: boolean; style?: stylex.StyleXStyles }) {
  const ref = useElement(props.controller.content)
  return (
    <div ref={ref} popover="manual" {...stylex.props(shared.layerReset, styles.popover, props.style)}>
      {props.arrow && <span aria-hidden="true" {...stylex.props(styles.arrow)} />}
      {props.children}
    </div>
  )
}

export type DialogProps = {
  controller: DialogController
  title: string
  description?: string
  children?: ReactNode
  /** Buttons, end aligned. */
  footer?: ReactNode
  /** Show a close button in the header. Default true for dialogs, false for sheets. */
  closeButton?: boolean
}

/**
 * A modal dialog or sheet on `<dialog>`. Rendered always (a closed dialog is
 * not displayed); mount it conditionally if its content is expensive.
 */
export function Dialog(props: DialogProps) {
  const { controller } = props
  const dialogRef = useElement(controller.content)
  const surfaceRef = useElement(controller.surface)
  const titleRef = useElement(controller.title)
  const descriptionRef = useElement(controller.description)
  const sheet = controller.presentation === "sheet"
  return (
    <dialog ref={dialogRef} {...stylex.props(shared.layerReset, styles.dialog, sheet && styles.sheetPlacement)}>
      <div ref={surfaceRef} {...stylex.props(styles.surface, sheet && styles.sheetSurface)}>
        <header {...stylex.props(styles.header)}>
          <h2 ref={titleRef} {...stylex.props(styles.title)}>
            {props.title}
          </h2>
          {(props.closeButton ?? !sheet) && (
            <IconButton
              label="Close"
              size="small"
              icon={<CloseIcon size={14} />}
              onClick={() => controller.close("button")}
            />
          )}
        </header>
        {props.description && (
          <p ref={descriptionRef} {...stylex.props(styles.description)}>
            {props.description}
          </p>
        )}
        {props.children && <div {...stylex.props(styles.body)}>{props.children}</div>}
        {props.footer && <footer {...stylex.props(styles.footer)}>{props.footer}</footer>}
      </div>
    </dialog>
  )
}

const sheetIn = stylex.keyframes({
  from: { transform: "translateY(-12px)", opacity: 0 },
  to: { transform: "translateY(0)", opacity: 1 },
})

const fadeIn = stylex.keyframes({
  from: { opacity: 0 },
  to: { opacity: 1 },
})
const layerIn = stylex.keyframes({
  from: { opacity: 0, transform: "scale(0.98)" },
  to: { opacity: 1, transform: "scale(1)" },
})

const styles = stylex.create({
  popover: {
    position: "fixed",
    minWidth: "160px",
    maxWidth: "min(420px, var(--ui-available-width, 100vw))",
    maxHeight: "var(--ui-available-height, 80vh)",
    padding: space.lg,
    boxSizing: "border-box",
    backgroundColor: color.popoverBackground,
    backdropFilter: "blur(24px) saturate(1.6)",
    borderRadius: radius.popover,
    boxShadow: shadow.popover,
    outline: "none",
    animationName: layerIn,
    animationDuration: motion.durationFast,
    animationTimingFunction: motion.easeOut,
  },
  arrow: {
    position: "absolute",
    width: "10px",
    height: "10px",
    // The arrow offset comes from the positioning function in physical pixels.
    left: "var(--ui-arrow-x, 50%)",
    top: "-5px",
    transform: "rotate(45deg)",
    backgroundColor: color.popoverBackground,
    boxShadow: `-0.5px -0.5px 0 ${color.layerBorder}`,
  },
  dialog: {
    // A modal `<dialog>` is centered by the browser's own `margin: auto`,
    // which the shared layer reset (written for positioned popovers) removes.
    margin: "auto",
    // 16 px from each edge at any size: 32 px off both axes.
    inlineSize: "min(480px, calc(100vw - 32px))",
    maxInlineSize: "none",
    // Never taller than the viewport: the surface is held to the same bound and its body scrolls.
    maxBlockSize: "calc(100dvh - 32px)",
    background: "transparent",
    "::backdrop": {
      backgroundColor: color.backdrop,
      animationName: fadeIn,
      animationDuration: motion.durationNormal,
    },
  },
  sheetPlacement: {
    // A sheet hangs from the top edge (the window's title area on the Mac).
    marginBlockStart: 0,
  },
  surface: {
    display: "flex",
    flexDirection: "column",
    gap: space.md,
    maxBlockSize: "calc(100dvh - 32px)",
    minBlockSize: 0,
    padding: space.xl,
    boxSizing: "border-box",
    backgroundColor: color.dialogBackground,
    borderRadius: radius.dialog,
    boxShadow: shadow.dialog,
    animationName: layerIn,
    animationDuration: motion.durationNormal,
    animationTimingFunction: motion.easeOut,
  },
  sheetSurface: {
    borderStartStartRadius: 0,
    borderStartEndRadius: 0,
    animationName: sheetIn,
  },
  header: { display: "flex", alignItems: "center", justifyContent: "space-between", gap: space.md, flexShrink: 0 },
  title: { margin: 0, minInlineSize: 0, overflowWrap: "anywhere", fontSize: font.sizeTitle3, fontWeight: font.weightSemibold },
  description: { margin: 0, flexShrink: 0, overflowWrap: "anywhere", color: color.secondaryLabel },
  body: {
    display: "flex",
    flexDirection: "column",
    gap: space.md,
    flexGrow: 1,
    flexShrink: 1,
    minBlockSize: 0,
    // overflow-block is not in Safari 17.5; in our horizontal writing mode block is y.
    overflowY: "auto",
    overscrollBehavior: "contain",
  },
  footer: { display: "flex", flexWrap: "wrap", justifyContent: "flex-end", gap: space.md, flexShrink: 0, marginBlockStart: space.sm },
})
