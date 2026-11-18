/** Views for Toggle (button and switch), SplitView and the toast region. */

import * as stylex from "@stylexjs/stylex"
import { useElement, useSignal } from "@inline/reactive/react"
import type { ReactNode } from "react"
import type { PaneSpec, SplitViewController } from "../split-view/controller"
import type { Toast, ToastQueue } from "../toast/controller"
import type { ToggleController } from "../toggle/controller"
import { color } from "../tokens/color.stylex"
import { font } from "../tokens/font.stylex"
import { layer } from "../tokens/layer.stylex"
import { motion } from "../tokens/motion.stylex"
import { radius } from "../tokens/radius.stylex"
import { shadow } from "../tokens/shadow.stylex"
import { size } from "../tokens/size.stylex"
import { space } from "../tokens/space.stylex"
import { Button } from "./Button"
import { CloseIcon } from "./icons"
import { shared } from "./styles"

/** A two-state toolbar or segmented button (`aria-pressed`). */
export function ToggleButton(props: { controller: ToggleController; children: ReactNode; label?: string }) {
  const ref = useElement(props.controller.root)
  const pressed = useSignal(props.controller.pressed)
  return (
    <button
      type="button"
      aria-label={props.label}
      ref={ref}
      {...stylex.props(styles.toggle, shared.focusRing, pressed && styles.togglePressed)}
    >
      {props.children}
    </button>
  )
}

/** An on/off switch (`role="switch"`) with a visible label. */
export function Switch(props: { controller: ToggleController; label: string }) {
  const ref = useElement(props.controller.root)
  const on = useSignal(props.controller.pressed)
  const disabled = useSignal(props.controller.disabled)
  return (
    <label {...stylex.props(styles.switchRow, disabled && styles.disabled)}>
      <button type="button" ref={ref} {...stylex.props(styles.switchTrack, shared.focusRing, on && styles.switchOn)}>
        <span {...stylex.props(styles.switchThumb, on && styles.switchThumbOn)} />
      </button>
      <span>{props.label}</span>
    </label>
  )
}

/** Panes side by side (or stacked) with draggable, keyboard-resizable separators. */
export function SplitView(props: {
  controller: SplitViewController
  panes: ReadonlyArray<{ id: string; content: ReactNode }>
  style?: stylex.StyleXStyles
}) {
  const ref = useElement(props.controller.root)
  const vertical = props.controller.orientation === "vertical"
  return (
    <div ref={ref} {...stylex.props(styles.split, vertical && styles.splitVertical, props.style)}>
      {props.panes.map((pane, index) => (
        <SplitPaneAndSeparator
          key={pane.id}
          controller={props.controller}
          id={pane.id}
          index={index}
          last={index === props.panes.length - 1}
        >
          {pane.content}
        </SplitPaneAndSeparator>
      ))}
    </div>
  )
}

function SplitPaneAndSeparator(props: { controller: SplitViewController; id: string; index: number; last: boolean; children: ReactNode }) {
  const paneRef = useElement(props.controller.pane(props.id))
  const separatorRef = useElement(props.controller.separator(props.index))
  const paneSize = useSignal(props.controller.size(props.id))
  const collapsed = useSignal(props.controller.isCollapsed(props.id))
  const flex = props.controller.isFlexible(props.id)
  const vertical = props.controller.orientation === "vertical"
  return (
    <>
      <div
        ref={paneRef}
        {...stylex.props(
          styles.pane,
          flex ? styles.flexPane : vertical ? dynamic.height(paneSize) : dynamic.width(paneSize),
          collapsed && styles.collapsed,
        )}
      >
        {props.children}
      </div>
      {!props.last && (
        <div ref={separatorRef} {...stylex.props(styles.separator, vertical && styles.separatorVertical, shared.focusRing)} />
      )}
    </>
  )
}

/** The toast landmark. Mount one per window. */
export function ToastRegion(props: { queue: ToastQueue }) {
  const ref = useElement(props.queue.region)
  const toasts = useSignal(props.queue.visible)
  return (
    <section ref={ref} popover="manual" {...stylex.props(shared.layerReset, styles.region)}>
      <ol {...stylex.props(styles.toastList)}>
        {toasts.map((toast) => (
          <ToastView key={toast.id} toast={toast} queue={props.queue} />
        ))}
      </ol>
    </section>
  )
}

function ToastView(props: { toast: Toast; queue: ToastQueue }) {
  const { toast } = props
  // The live element holds the text only, so a screen reader reads the title
  // and description once, without the buttons' names.
  return (
    <li {...stylex.props(styles.toast, toneStyles[toast.tone])}>
      <div role={toast.tone === "error" ? "alert" : "status"} aria-atomic="true" {...stylex.props(styles.toastText)}>
        <span {...stylex.props(styles.toastTitle)}>{toast.title}</span>
        {toast.description && <span {...stylex.props(styles.toastDescription)}>{toast.description}</span>}
      </div>
      {toast.action && (
        <Button
          size="small"
          style={styles.toastAction}
          onClick={() => {
            toast.action?.onAction()
            props.queue.dismiss(toast.id)
          }}
        >
          {toast.action.label}
        </Button>
      )}
      <button
        type="button"
        aria-label="Dismiss"
        onClick={() => props.queue.dismiss(toast.id)}
        {...stylex.props(styles.toastClose, shared.focusRing)}
      >
        <CloseIcon size={12} />
      </button>
    </li>
  )
}

export type { PaneSpec }

const layerIn = stylex.keyframes({
  from: { opacity: 0, transform: "scale(0.98)" },
  to: { opacity: 1, transform: "scale(1)" },
})

const styles = stylex.create({
  toggle: {
    display: "inline-flex",
    alignItems: "center",
    justifyContent: "center",
    gap: space.xs,
    height: size.control,
    minWidth: size.control,
    paddingInline: space.md,
    borderStyle: "none",
    borderRadius: radius.control,
    backgroundColor: { default: "transparent", ":hover": color.controlHover },
    color: color.controlText,
    fontFamily: font.familySystem,
    fontSize: font.sizeBody,
    cursor: "default",
  },
  togglePressed: {
    backgroundColor: { default: color.controlPressed, ":hover": color.controlPressed },
    color: color.accent,
  },
  switchRow: { display: "inline-flex", alignItems: "center", gap: space.md, cursor: "default" },
  disabled: { opacity: 0.5 },
  switchTrack: {
    position: "relative",
    width: "32px",
    height: "18px",
    padding: 0,
    borderStyle: "none",
    borderRadius: radius.pill,
    backgroundColor: color.controlTrack,
    transitionProperty: "background-color",
    transitionDuration: motion.durationFast,
    flexShrink: 0,
  },
  switchOn: { backgroundColor: color.accent },
  switchThumb: {
    position: "absolute",
    top: "2px",
    insetInlineStart: "2px",
    width: "14px",
    height: "14px",
    borderRadius: radius.pill,
    backgroundColor: "#ffffff",
    boxShadow: "0 1px 2px rgb(0 0 0 / 0.25)",
    transitionProperty: "inset-inline-start",
    transitionDuration: motion.durationFast,
    transitionTimingFunction: motion.easeStandard,
  },
  switchThumbOn: { insetInlineStart: "16px" },
  split: { display: "flex", flexDirection: "row", minWidth: 0, minHeight: 0, height: "100%" },
  splitVertical: { flexDirection: "column" },
  pane: { position: "relative", minWidth: 0, minHeight: 0, overflow: "hidden", flexShrink: 0 },
  flexPane: { flexGrow: 1, flexShrink: 1, flexBasis: 0 },
  collapsed: { visibility: "hidden" },
  separator: {
    position: "relative",
    zIndex: layer.resizer,
    flexShrink: 0,
    width: "1px",
    marginInline: "-3px",
    borderInlineWidth: "3px",
    borderInlineStyle: "solid",
    borderInlineColor: "transparent",
    backgroundClip: "padding-box",
    backgroundColor: color.separator,
    cursor: "col-resize",
    touchAction: "none",
  },
  separatorVertical: {
    width: "auto",
    height: "1px",
    marginInline: 0,
    borderInlineWidth: 0,
    marginBlock: "-3px",
    borderBlockWidth: "3px",
    borderBlockStyle: "solid",
    borderBlockColor: "transparent",
    cursor: "row-resize",
  },
  region: {
    // Placed by the queue: the container's (or window's) inline-end, block-end corner.
    position: "fixed",
    inset: "auto",
    insetBlockEnd: "var(--ui-toast-inset-block-end, 16px)",
    insetInlineEnd: "var(--ui-toast-inset-inline-end, 16px)",
    background: "transparent",
    overflow: "visible",
  },
  // Newest last, nearest the corner, as on the Mac.
  toastList: { display: "flex", flexDirection: "column", alignItems: "flex-end", gap: space.md, margin: 0, padding: 0, listStyle: "none" },
  toast: {
    display: "flex",
    alignItems: "center",
    gap: space.md,
    inlineSize: "min(360px, var(--ui-toast-max-inline-size, calc(100vw - 32px)))",
    boxSizing: "border-box",
    paddingBlock: space.md,
    paddingInlineStart: space.lg,
    paddingInlineEnd: space.sm,
    backgroundColor: color.popoverBackground,
    backdropFilter: "blur(24px) saturate(1.6)",
    borderRadius: radius.popover,
    boxShadow: shadow.toast,
    borderInlineStartWidth: "3px",
    borderInlineStartStyle: "solid",
    animationName: layerIn,
    animationDuration: motion.durationNormal,
    animationTimingFunction: motion.easeOut,
  },
  toastText: { display: "flex", flexDirection: "column", gap: space.xxs, flexGrow: 1, minInlineSize: 0 },
  toastTitle: { fontWeight: font.weightMedium, overflowWrap: "anywhere" },
  // A long description wraps; it never widens the toast or hides behind the buttons.
  toastDescription: { color: color.secondaryLabel, fontSize: font.sizeCallout, overflowWrap: "anywhere", whiteSpace: "normal" },
  toastAction: { flexShrink: 0 },
  toastClose: {
    flexShrink: 0,
    display: "inline-flex",
    alignItems: "center",
    justifyContent: "center",
    inlineSize: size.controlSmall,
    blockSize: size.controlSmall,
    borderStyle: "none",
    borderRadius: radius.control,
    backgroundColor: { default: "transparent", ":hover": color.controlHover },
    color: color.secondaryLabel,
  },
})

const toneStyles = stylex.create({
  neutral: { borderInlineStartColor: "transparent" },
  success: { borderInlineStartColor: color.green },
  warning: { borderInlineStartColor: color.orange },
  error: { borderInlineStartColor: color.red },
})

const dynamic = stylex.create({
  width: (value: number) => ({ width: `${value}px` }),
  height: (value: number) => ({ height: `${value}px` }),
})
