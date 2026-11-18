/**
 * The menu kit chunk (`@inline/ui/menu-kit`): everything a menu needs beyond
 * the trigger, loaded on first use or on the idle lane (`menuKit` in
 * `../context-menu/kit.ts`). Keep it to re-exports; first-frame code imports
 * none of these statically, so they stay out of the initial JavaScript.
 */

export { ContextMenuController } from "../context-menu/controller"
export { MenuController } from "../menu/controller"
export { ContextMenuArea, MenuButton, MenuContent } from "./Menu"
