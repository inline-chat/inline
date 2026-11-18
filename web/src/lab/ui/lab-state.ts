/**
 * The UI lab's state and controls for browser checks without screenshots.
 *
 * `globalThis.__uiLab` reads (plain data):
 *   - `overlays()`: each dialog (`dialog`, `alert`, `sheet`, `long`): open,
 *     its `<dialog>` and surface rectangles, the body's scroll and client
 *     heights, and the viewport. A centered dialog has equal space left and
 *     right and above and below; a sheet's top is 0; neither is ever taller
 *     or wider than the viewport, and the long one scrolls in its body.
 *   - `toasts()`: the region's rectangle, the container's (when anchored),
 *     the placement variables, the visible titles, and the live texts (what
 *     a screen reader reads, once per toast).
 *   - `menu()`: the open menu's items with their accessible name
 *     (`aria-label`), `aria-keyshortcuts` and visible text.
 *   - `lazyMenu()`: the lazy context menu demo: waiting, open, loaded.
 *
 * `globalThis.__uiLabControl`:
 *   - `openDialog(name)`, `closeDialogs()`.
 *   - `toast(input?)`, `toastLong()`, `clearToasts()`, `setToastAnchor("window" | "container")`.
 *   - `setLazyMenuDelay(ms)`: how long the lazy demo's first load takes.
 *   - `openLazyMenuAt(x, y)`: a secondary click on the demo target at a point.
 */

import { type ReadSignal, signal } from "@inline/reactive"
import {
  createSheet,
  DialogController,
  Lazy,
  LazyContextMenu,
  loadMenuKit,
  type MenuKitCore,
  type Rect,
  type ToastInput,
  ToastQueue,
} from "@inline/ui"

const rectOf = (element: Element | null | undefined): Rect | null => {
  if (!element) return null
  const r = element.getBoundingClientRect()
  return { x: Math.round(r.left), y: Math.round(r.top), width: Math.round(r.width), height: Math.round(r.height) }
}

// MARK: Overlays

export const labDialogs = {
  dialog: new DialogController(),
  alert: new DialogController({ role: "alertdialog" }),
  sheet: createSheet(),
  long: new DialogController(),
}

export type LabDialogName = keyof typeof labDialogs

const dialogState = (controller: DialogController) => {
  const title = document.getElementById(controller.titleId)
  const dialog = title?.closest("dialog") ?? null
  const surface = dialog?.firstElementChild ?? null
  // The body is the surface's scrolling child.
  const body = surface ? Array.from(surface.children).find((child) => getComputedStyle(child).overflowY === "auto") : null
  return {
    open: controller.isOpen.peek(),
    presentation: controller.presentation,
    dialog: rectOf(dialog),
    surface: rectOf(surface),
    body: body ? { scrollHeight: body.scrollHeight, clientHeight: body.clientHeight } : null,
    viewport: { width: window.innerWidth, height: window.innerHeight },
  }
}

// MARK: Toasts

export const labToasts = new ToastQueue({ max: 3, offset: { inline: 12, block: 12 } })
const toastAnchor = signal<"window" | "container">("window")
export const labToastAnchor: ReadSignal<"window" | "container"> = toastAnchor
export const setLabToastAnchor = (anchor: "window" | "container"): void => toastAnchor.set(anchor)

const LONG_DESCRIPTION =
  "The file is larger than this workspace allows. Ask an admin to raise the limit, or share a link to it instead; " +
  "a_very_long_unbroken_identifier_that_must_wrap_inside_the_toast_without_widening_it.pdf"

// MARK: Lazy menu

let lazyDelay = 800
const labKit = new Lazy<MenuKitCore>(
  () =>
    new Promise((resolve, reject) => {
      setTimeout(() => void loadMenuKit().then(resolve, reject), lazyDelay)
    }),
)

export const labLazyMenu = new LazyContextMenu({
  label: "Lazy demo",
  kit: labKit,
  items: [
    { type: "item", id: "edit", label: "Edit", shortcut: "⌘E" },
    { type: "item", id: "copy", label: "Copy Text", shortcut: "⌘C" },
    { type: "separator", id: "s" },
    { type: "item", id: "delete", label: "Delete", shortcut: "⌘⌫", destructive: true },
  ],
})

// MARK: Globals

const state = {
  overlays: () => Object.fromEntries(Object.entries(labDialogs).map(([name, controller]) => [name, dialogState(controller)])),
  toasts: () => {
    const region = document.getElementById(labToasts.id)
    const container = document.querySelector("[data-lab-toast-container]")
    return {
      anchor: toastAnchor.peek(),
      region: rectOf(region),
      container: toastAnchor.peek() === "container" ? rectOf(container) : null,
      vars: {
        insetInlineEnd: region?.style.getPropertyValue("--ui-toast-inset-inline-end") ?? "",
        insetBlockEnd: region?.style.getPropertyValue("--ui-toast-inset-block-end") ?? "",
        maxInlineSize: region?.style.getPropertyValue("--ui-toast-max-inline-size") ?? "",
      },
      visible: labToasts.visible.peek().map((toast) => toast.title),
      live: Array.from(region?.querySelectorAll("[role=status], [role=alert]") ?? []).map((node) => node.textContent ?? ""),
      toastRects: Array.from(region?.querySelectorAll("li") ?? []).map((node) => rectOf(node)),
    }
  },
  menu: () => {
    const menus = Array.from(document.querySelectorAll<HTMLElement>("[role=menu]")).filter((menu) => menu.matches(":popover-open"))
    const menu = menus[menus.length - 1]
    if (!menu) return null
    return {
      label: menu.getAttribute("aria-label") ?? menu.getAttribute("aria-labelledby"),
      items: Array.from(menu.querySelectorAll<HTMLElement>(":scope > [role^=menuitem]")).map((item) => ({
        role: item.getAttribute("role"),
        name: item.getAttribute("aria-label"),
        keyshortcuts: item.getAttribute("aria-keyshortcuts"),
        text: item.textContent,
      })),
    }
  },
  lazyMenu: () => ({
    delay: lazyDelay,
    loaded: labKit.peek() !== undefined,
    waiting: labLazyMenu.waiting.peek(),
    open: labLazyMenu.isOpen.peek(),
  }),
}

const control = {
  openDialog: (name: LabDialogName) => labDialogs[name].open(),
  closeDialogs: () => {
    for (const controller of Object.values(labDialogs)) controller.close("button")
  },
  toast: (input: Partial<ToastInput> = {}) => labToasts.show({ title: "Message sent", ...input }),
  toastLong: () =>
    labToasts.show({ title: "Could not upload quarterly-report-final-final.pdf", description: LONG_DESCRIPTION, tone: "warning", duration: Infinity }),
  clearToasts: () => labToasts.clear(),
  setToastAnchor: (anchor: "window" | "container") => toastAnchor.set(anchor),
  setLazyMenuDelay: (ms: number) => {
    lazyDelay = ms
  },
  openLazyMenuAt: (x: number, y: number) => {
    const target = document.querySelector("[data-lab-lazy-target]")
    if (!target) return false
    target.dispatchEvent(new PointerEvent("pointerdown", { bubbles: true, button: 2, pointerType: "mouse", clientX: x, clientY: y }))
    const event = new MouseEvent("contextmenu", { bubbles: true, cancelable: true, button: 2, clientX: x, clientY: y })
    target.dispatchEvent(event)
    return event.defaultPrevented
  },
}

Object.assign(globalThis, { __uiLab: state, __uiLabControl: control })
