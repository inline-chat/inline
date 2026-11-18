/**
 * Pure navigation over an ordered collection of keyed items, skipping the
 * ones that cannot take focus. Menus, listboxes, tabs and comboboxes share it.
 */

export type NavItem = { readonly id: string; readonly disabled?: boolean }

export type NavAction = "next" | "prev" | "first" | "last" | "pageDown" | "pageUp"

export type NavOptions = {
  /** Wrap from the last item to the first and back. */
  loop?: boolean
  /** Items moved by pageDown and pageUp. */
  pageSize?: number
  /** Whether disabled items can take focus (APG allows it for menus; we skip them by default). */
  focusDisabled?: boolean
}

const usable = (item: NavItem | undefined, options: NavOptions): item is NavItem =>
  !!item && (options.focusDisabled || !item.disabled)

const firstFrom = (items: readonly NavItem[], start: number, step: 1 | -1, options: NavOptions): string | null => {
  for (let index = start; index >= 0 && index < items.length; index += step) {
    const item = items[index]
    if (usable(item, options)) return item.id
  }
  return null
}

/** The item to move to, or `current` when there is nowhere to go. */
export const navigate = (
  items: readonly NavItem[],
  current: string | null,
  action: NavAction,
  options: NavOptions = {},
): string | null => {
  if (items.length === 0) return null
  const index = current === null ? -1 : items.findIndex((item) => item.id === current)
  const last = items.length - 1
  switch (action) {
    case "first":
      return firstFrom(items, 0, 1, options)
    case "last":
      return firstFrom(items, last, -1, options)
    case "next": {
      if (index < 0) return firstFrom(items, 0, 1, options)
      const found = firstFrom(items, index + 1, 1, options)
      if (found !== null) return found
      return options.loop ? firstFrom(items, 0, 1, options) : current
    }
    case "prev": {
      if (index < 0) return firstFrom(items, last, -1, options)
      const found = firstFrom(items, index - 1, -1, options)
      if (found !== null) return found
      return options.loop ? firstFrom(items, last, -1, options) : current
    }
    case "pageDown": {
      const target = Math.min(last, Math.max(index, 0) + (options.pageSize ?? 10))
      return firstFrom(items, target, -1, options) ?? firstFrom(items, target, 1, options)
    }
    case "pageUp": {
      const target = Math.max(0, (index < 0 ? last : index) - (options.pageSize ?? 10))
      return firstFrom(items, target, 1, options) ?? firstFrom(items, target, -1, options)
    }
  }
}

export const isUsable = (items: readonly NavItem[], id: string | null, options: NavOptions = {}): boolean =>
  id !== null && usable(items.find((item) => item.id === id), options)
