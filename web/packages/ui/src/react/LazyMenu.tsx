/**
 * The view half of `LazyContextMenu`: renders the menu kit's `MenuContent`
 * once the kit has loaded and the controller exists, nothing before. Tiny,
 * so a list can render it on its first frame without the menu's code.
 */

import { useSignal } from "@inline/reactive/react"
import { menuKit } from "../context-menu/kit"
import type { LazyContextMenu } from "../context-menu/lazy"

export function LazyMenuContent(props: { menu: LazyContextMenu }) {
  const controller = useSignal(props.menu.controller)
  const kit = useSignal(menuKit.value)
  if (!controller || !kit) return null
  const { MenuContent } = kit
  return <MenuContent menu={controller.menu} />
}
