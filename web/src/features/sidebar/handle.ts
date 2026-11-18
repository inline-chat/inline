/**
 * The sidebar's imperative handle, for commands that act on the region from
 * outside ("focus sidebar", reveal the selected chat). The shell creates one
 * with `new SidebarHandle()`, passes it to `SidebarView` as `handle`, and
 * calls it from the session's `attachView({ focusRegion })` hook. Calls before
 * the view mounts, or after it unmounts, do nothing and return false.
 */

export type SidebarHandleTarget = {
  focus(): boolean
  revealSelected(): boolean
  /** Plain data about the list (window, focus, unread below), for labs and tests. */
  snapshot(): SidebarSnapshot
}

export type SidebarSnapshot = {
  readonly count: number
  readonly status: "loading" | "empty" | "list"
  readonly range: { readonly first: number; readonly last: number }
  readonly rendered: number
  readonly currentKey: string | undefined
  readonly selectedKey: string | undefined
  readonly hasFocus: boolean
  readonly unreadBelow: { readonly count: number; readonly target?: number }
  readonly contextKey: string | undefined
  readonly typeahead: string
  /** Recycled row elements, including empty spares. */
  readonly slots: number
  /** Rows drawn lite (fast scroll), not yet filled in. */
  readonly lite: number
  readonly fast: boolean
}

export class SidebarHandle {
  #target: SidebarHandleTarget | undefined

  /** Move keyboard focus into the list: the selected chat, else the last focused or the first row. */
  focus(): boolean {
    return this.#target?.focus() ?? false
  }

  /** Scroll the selected chat into view. */
  revealSelected(): boolean {
    return this.#target?.revealSelected() ?? false
  }

  snapshot(): SidebarSnapshot | undefined {
    return this.#target?.snapshot()
  }

  get attached(): boolean {
    return this.#target !== undefined
  }

  /** Called by the view's controller. Returns the unbind function. */
  bind(target: SidebarHandleTarget): () => void {
    this.#target = target
    return () => {
      if (this.#target === target) this.#target = undefined
    }
  }
}
