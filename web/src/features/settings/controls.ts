/**
 * Small controllers behind the settings rows: a switch bound to a setting's
 * signal, the "Clear Cached Media" action, and a part that refreshes the
 * storage estimate when the Data & Storage page shows. Framework-free.
 */

import type { Capability, PersistentStorage } from "@inline/platform"
import { effect, signal, type Dispose, type ReadSignal } from "@inline/reactive"
import { ToggleController, type Part } from "@inline/ui"

/**
 * A kit `ToggleController` (role `switch`) that shows `source` and writes
 * through `set`. A change from elsewhere (another tab, the core) moves the
 * switch; a write the store refuses springs back.
 */
export class BoundToggle {
  readonly toggle: ToggleController
  readonly #stop: Dispose

  constructor(source: ReadSignal<boolean>, set: (on: boolean) => void, options: { readonly disabled?: boolean } = {}) {
    this.toggle = new ToggleController({
      kind: "switch",
      pressed: source.peek(),
      disabled: options.disabled ?? false,
      onChange: (on) => {
        set(on)
        const actual = source.peek()
        if (actual !== on) this.toggle.setPressed(actual)
      },
    })
    this.#stop = effect(() => {
      this.toggle.setPressed(source.get())
    })
  }

  dispose(): void {
    this.#stop()
  }
}

export type ClearMediaStatus = "idle" | "clearing" | "cleared" | "failed"

/** "Clear Cached Media": unavailable without a handler, one run at a time, then a fresh estimate. */
export class ClearMediaAction {
  readonly available: boolean
  readonly status: ReadSignal<ClearMediaStatus>
  readonly #status = signal<ClearMediaStatus>("idle")
  readonly #clear: (() => Promise<void> | void) | undefined
  readonly #refresh: (() => Promise<void>) | undefined

  constructor(options: { readonly clear?: () => Promise<void> | void; readonly refresh?: () => Promise<void> }) {
    this.#clear = options.clear
    this.#refresh = options.refresh
    this.available = options.clear !== undefined
    this.status = this.#status
  }

  async run(): Promise<void> {
    if (!this.#clear || this.#status.peek() === "clearing") return
    this.#status.set("clearing")
    try {
      await this.#clear()
      this.#status.set("cleared")
    } catch {
      this.#status.set("failed")
    }
    try {
      await this.#refresh?.()
    } catch {
      // The estimate keeps its last value.
    }
  }
}

export const clearMediaStatusText = (status: ClearMediaStatus): string | undefined => {
  switch (status) {
    case "clearing":
      return "Clearing…"
    case "cleared":
      return "Cached media cleared."
    case "failed":
      return "Could not clear cached media. Try again."
    case "idle":
      return undefined
  }
}

/** Attach to the Data & Storage page: asks for a fresh estimate each time it shows. */
export const refreshEstimateOnShow = (storage: Capability<PersistentStorage>): Part => ({
  attach: () => {
    if (storage.available) void storage.refreshEstimate().catch(() => undefined)
    return () => undefined
  },
})
