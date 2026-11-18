/**
 * Row action views: the quick actions capsule a row shows while active, and
 * the list-level region and menu that host the shared context menu.
 * State lives in `MessageActionsController` (actions.ts).
 */

import * as stylex from "@stylexjs/stylex"
import type { MessageRowId } from "@inline/core-protocol"
import { useElement } from "@inline/reactive/react"
import type { Rect } from "@inline/ui"
import { IconButton, LazyMenuContent } from "@inline/ui/react"
import { color } from "@inline/ui/tokens/color.stylex"
import { layer } from "@inline/ui/tokens/layer.stylex"
import { radius } from "@inline/ui/tokens/radius.stylex"
import { space } from "@inline/ui/tokens/space.stylex"
import type { MouseEvent, ReactNode } from "react"
import { type MessageActionsController, QUICK_ACTION_ATTRIBUTE, quickActions } from "./actions"
import { ActionIcon } from "./icons"

const rectOf = (element: Element): Rect => {
  const rect = element.getBoundingClientRect()
  return { x: rect.x, y: rect.y, width: rect.width, height: rect.height }
}

/**
 * The quick actions of one row (Mac `MessageQuickActionsView`): the row's
 * actions marked `quick`, then "More Actions", which opens the row's menu at
 * the button. Absolutely positioned over the row's top edge, so showing it
 * never moves layout.
 */
export function QuickActions(props: { rowId: MessageRowId; controller: MessageActionsController }) {
  const { rowId, controller } = props
  const actions = quickActions(controller.actionsFor(rowId))
  const openMore = (event: MouseEvent<HTMLButtonElement>) => {
    // `detail` is 0 for a click from the keyboard (Enter or Space).
    controller.openMenu(rowId, rectOf(event.currentTarget), { keyboard: event.detail === 0 })
  }
  return (
    <div role="toolbar" aria-label="Message actions" {...stylex.props(styles.capsule)}>
      {actions.map((action) => (
        <IconButton
          key={action.id}
          size="small"
          label={action.label}
          icon={<ActionIcon icon={action.icon} />}
          disabled={!action.enabled}
          {...{ [QUICK_ACTION_ATTRIBUTE]: action.id }}
          style={styles.button}
          onClick={(event) => controller.runQuick(rowId, action, rectOf(event.currentTarget))}
        />
      ))}
      <IconButton
        size="small"
        label="More Actions"
        aria-haspopup="menu"
        icon={<ActionIcon icon="more" />}
        style={styles.button}
        onClick={openMore}
      />
    </div>
  )
}

/**
 * The shared context menu of a message list. Render it once, inside the
 * element the controller's `list` part is attached to or anywhere else. It
 * renders nothing until the menu's code has loaded (the first request, or
 * the app's warm-up), so the rows' first frame carries none of it.
 */
export function MessageActionsMenu(props: { controller: MessageActionsController }) {
  return <LazyMenuContent menu={props.controller.contextMenu} />
}

/**
 * Convenience wrapper: a block element with the controller's `list` part
 * attached (hover, focus and secondary click for every row inside) and the
 * shared menu. Wrap the timeline's scroll container with it, not its content
 * element, so the content's children stay rows only.
 */
export function MessageActionsRegion(props: {
  controller: MessageActionsController
  children: ReactNode
  style?: stylex.StyleXStyles
}) {
  const ref = useElement(props.controller.list)
  return (
    <div ref={ref} {...stylex.props(props.style)}>
      {props.children}
      <MessageActionsMenu controller={props.controller} />
    </div>
  )
}

const styles = stylex.create({
  capsule: {
    position: "absolute",
    insetBlockStart: "-13px",
    insetInlineEnd: space.xl,
    zIndex: layer.raised,
    display: "flex",
    alignItems: "center",
    gap: space.xxs,
    padding: space.xxs,
    blockSize: "26px",
    boxSizing: "border-box",
    borderRadius: radius.pill,
    backgroundColor: color.popoverBackground,
    boxShadow: `0 0 0 0.5px ${color.layerBorder}, 0 2px 8px light-dark(rgb(0 0 0 / 0.1), rgb(0 0 0 / 0.4))`,
    color: color.secondaryLabel,
    userSelect: "none",
    outline: { default: null, "@media (forced-colors: active)": "1px solid CanvasText" },
  },
  button: {
    borderRadius: radius.pill,
    color: color.secondaryLabel,
  },
})
