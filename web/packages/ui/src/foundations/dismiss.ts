/**
 * Dismissal for layers: outside press, Escape, and focus leaving.
 *
 * Layers form a stack per document, in the order they open. A layer may
 * name a parent (a submenu names its menu); a layer's tree is the layer and
 * every layer opened under it. Rules:
 *
 * - Escape dismisses only the topmost layer that accepts it, one level per press.
 * - An outside press walks down from the top. Each layer whose tree does not
 *   contain the target is dismissed, until one does or one does not accept
 *   outside presses. So a press inside a menu closes its open submenu and
 *   leaves the menu; a press outside both closes both.
 * - Focus moving outside a layer's tree dismisses layers that ask for it.
 *
 * Presses on a layer's `ignore` elements (its trigger) are left to the trigger,
 * so a click on an open menu's button toggles it closed instead of reopening it.
 *
 * Layers shown with `popover="manual"` rely on this for dismissal; the Popover
 * API's own light dismiss is not used, so there is exactly one owner.
 */

import { contains, type Dispose, isNode, listen } from "./dom"

export type DismissReason = "escape" | "outside-press" | "focus-outside"

type ElementList = Array<Element | null | undefined>

export type DismissLayerOptions = {
  /** The layer's own elements; presses and focus inside them are inside. */
  elements: () => ElementList
  /** Elements whose presses are neither inside nor outside (the trigger). */
  ignore?: () => ElementList
  parent?: DismissLayer | null
  onDismiss: (reason: DismissReason, event: Event) => void
  /** Default true. */
  escape?: boolean
  /** Default true. */
  outsidePress?: boolean
  /** Default false. */
  focusOutside?: boolean
}

export interface DismissLayer {
  readonly parent: DismissLayer | null
  readonly disposed: boolean
  /** True if `node` is inside this layer or any layer opened under it. */
  contains(node: unknown): boolean
  dispose(): void
}

type LayerRecord = DismissLayer & { options: DismissLayerOptions; inOwn(node: unknown): boolean; ignores(node: unknown): boolean }

type Stack = { layers: LayerRecord[]; detach: Dispose | null }

const stacks = new WeakMap<Document, Stack>()

const stackFor = (doc: Document): Stack => {
  let stack = stacks.get(doc)
  if (!stack) {
    stack = { layers: [], detach: null }
    stacks.set(doc, stack)
  }
  return stack
}

const isUnder = (layer: DismissLayer, ancestor: DismissLayer): boolean => {
  for (let current: DismissLayer | null = layer; current; current = current.parent) {
    if (current === ancestor) return true
  }
  return false
}

const install = (doc: Document, stack: Stack): Dispose => {
  const onPointerDown = (event: PointerEvent | MouseEvent) => {
    const target = event.target
    for (const layer of [...stack.layers].reverse()) {
      if (layer.disposed) continue
      if (layer.contains(target) || layer.ignores(target)) return
      if (layer.options.outsidePress === false) return
      layer.options.onDismiss("outside-press", event)
    }
  }
  const onKeyDown = (event: KeyboardEvent) => {
    if (event.key !== "Escape" || event.isComposing || event.defaultPrevented) return
    for (let index = stack.layers.length - 1; index >= 0; index--) {
      const layer = stack.layers[index]!
      if (layer.disposed || layer.options.escape === false) continue
      event.preventDefault()
      event.stopPropagation()
      layer.options.onDismiss("escape", event)
      return
    }
  }
  const onFocusIn = (event: FocusEvent) => {
    const target = event.target
    if (!isNode(target) || target === doc.body || target === doc.documentElement) return
    for (const layer of [...stack.layers].reverse()) {
      if (layer.disposed) continue
      if (layer.contains(target) || layer.ignores(target)) return
      if (layer.options.focusOutside) layer.options.onDismiss("focus-outside", event)
    }
  }
  const disposers = [
    listen(doc, "pointerdown", onPointerDown, true),
    listen(doc, "keydown", onKeyDown, true),
    listen(doc, "focusin", onFocusIn, true),
  ]
  return () => {
    for (const dispose of disposers) dispose()
  }
}

/** Open a dismissable layer. Dispose it when the layer closes. */
export const pushDismissLayer = (doc: Document, options: DismissLayerOptions): DismissLayer => {
  const stack = stackFor(doc)
  const listIncludes = (list: ElementList | undefined, node: unknown) => !!list?.some((element) => contains(element, node))
  const layer: LayerRecord = {
    options,
    parent: options.parent ?? null,
    disposed: false,
    inOwn: (node) => listIncludes(options.elements(), node),
    // A press on an ancestor's trigger is that trigger's business too.
    ignores: (node) =>
      listIncludes(options.ignore?.(), node) || !!(layer.parent as LayerRecord | null)?.ignores(node),
    contains(node) {
      if (layer.inOwn(node)) return true
      return stack.layers.some((other) => other !== layer && !other.disposed && isUnder(other, layer) && other.inOwn(node))
    },
    dispose() {
      if (layer.disposed) return
      ;(layer as { disposed: boolean }).disposed = true
      const index = stack.layers.indexOf(layer)
      if (index >= 0) stack.layers.splice(index, 1)
      if (stack.layers.length === 0) {
        stack.detach?.()
        stack.detach = null
      }
    },
  }
  stack.layers.push(layer)
  if (!stack.detach) stack.detach = install(doc, stack)
  return layer
}

/** Layers currently open in a document, bottom first. For tests and debugging. */
export const openLayerCount = (doc: Document): number => stacks.get(doc)?.layers.length ?? 0
