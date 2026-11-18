/**
 * The menu kit chunk: `MenuController`, `ContextMenuController` and the
 * React `MenuContent`, in one code-split chunk (`@inline/ui/menu-kit`,
 * source `src/react/menu-kit.tsx`). Nothing on the first frame imports it
 * statically; `LazyContextMenu` and `LazyMenuContent` load it through
 * `menuKit` on the first request, and the app warms it on the idle lane.
 *
 * The app's chunk table should name it with the same specifier, so both
 * resolve to one chunk: `menus: () => import("@inline/ui/menu-kit")`.
 */

import { Lazy } from "../foundations/lazy"
import type { ContextMenuController } from "./controller"

/** What `LazyContextMenu` needs from the chunk. */
export type MenuKitCore = { readonly ContextMenuController: typeof ContextMenuController }

/** The whole chunk's exports (the view's `MenuContent` included). */
export type MenuKit = typeof import("../react/menu-kit")

/** The shared holder: one load for every lazy menu in the page. */
export const menuKit: Lazy<MenuKit> = new Lazy(() => import("../react/menu-kit"))

/** Load the menu kit (idempotent). For the idle lane. */
export const loadMenuKit = (): Promise<MenuKit> => menuKit.load()
