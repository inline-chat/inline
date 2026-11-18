/**
 * The render-count harness for render budget tests (web/docs/reactivity.md,
 * "Render budget tests").
 *
 * A component calls `countRender(name)` at the top of its body. It costs one
 * null check when no counter is installed, so real components can keep the
 * call. A test installs a counter, mounts components with `mount`, acts, and
 * asserts on the counts.
 *
 * Measure budgets without StrictMode: it renders every component twice.
 */

import type { ReactNode } from "react"
import { act } from "react"
import { createRoot, type Root } from "react-dom/client"

export interface RenderCounter {
  /** Renders of `name` since the counter was installed or last reset. */
  count(name: string): number
  /** Renders of every name that starts with `prefix`. */
  countPrefix(prefix: string): number
  /** All counts, for a readable failure message. */
  counts(): Record<string, number>
  total(): number
  reset(): void
  /** Uninstall. Further renders are not counted. */
  dispose(): void
}

let active: Map<string, number> | null = null

/** Record one render of `name`. Call it at the top of a component's body. */
export function countRender(name: string): void {
  if (active === null) return
  active.set(name, (active.get(name) ?? 0) + 1)
}

/** Install a counter; the previous one, if any, stops counting. */
export function createRenderCounter(): RenderCounter {
  const counts = new Map<string, number>()
  active = counts
  return {
    count: (name) => counts.get(name) ?? 0,
    countPrefix: (prefix) => {
      let total = 0
      for (const [name, value] of counts) if (name.startsWith(prefix)) total += value
      return total
    },
    counts: () => Object.fromEntries(counts),
    total: () => {
      let total = 0
      for (const value of counts.values()) total += value
      return total
    },
    reset: () => counts.clear(),
    dispose: () => {
      if (active === counts) active = null
    },
  }
}

export interface Mounted {
  readonly container: HTMLElement
  readonly root: Root
  /** Render a new element into the same root. */
  rerender(node: ReactNode): void
  unmount(): void
}

/** Mount into a fresh container inside `act`. Needs a DOM (happy-dom in Vitest). */
export function mount(node: ReactNode): Mounted {
  ;(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true
  const container = document.createElement("div")
  document.body.append(container)
  const root = createRoot(container)
  act(() => root.render(node))
  return {
    container,
    root,
    rerender: (next) => act(() => root.render(next)),
    unmount: () => {
      act(() => root.unmount())
      container.remove()
    },
  }
}

/** Run `fn` inside React's `act`, so every update it causes is rendered before it returns. */
export function update(fn: () => void): void {
  act(fn)
}
