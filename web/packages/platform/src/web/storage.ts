/**
 * Persistent storage. Eviction would drop unsent intents (core.md), so the app
 * asks for persistence, but only where the browser decides without a prompt:
 * Chromium grants or denies by engagement, Safari grants. Firefox shows a
 * prompt, so it is not asked there; the earlier build did the same.
 */

import { signal } from "@inline/reactive"
import { available, unavailable, type Capability } from "../capability"
import type { PersistentStorage, StorageEstimate } from "../platform"
import { toEstimate, type WebEnv } from "./env"

/** Firefox prompts for `persist()`. Gecko forks carry the same token. */
export const promptsForPersistence = (userAgent: string): boolean => /\bFirefox\//.test(userAgent)

export const createWebStorage = (env: WebEnv): Capability<PersistentStorage> => {
  const manager = env.navigator.storage
  if (!manager) return unavailable("no-storage-manager")

  const persisted = signal<boolean | null>(null)
  const estimate = signal<StorageEstimate | null>(null, {
    equals: (a, b) => a === b || (a !== null && b !== null && a.usage === b.usage && a.quota === b.quota),
  })
  const canRequestSilently = typeof manager.persist === "function" && !promptsForPersistence(env.navigator.userAgent)

  const readPersisted = async (): Promise<boolean> => {
    try {
      const value = typeof manager.persisted === "function" ? await manager.persisted() : false
      persisted.set(value)
      return value
    } catch {
      return persisted.peek() ?? false
    }
  }

  const refreshEstimate = async () => {
    if (typeof manager.estimate !== "function") return
    try {
      estimate.set(toEstimate(await manager.estimate()))
    } catch {
      // Keep the last value.
    }
  }

  void readPersisted()
  void refreshEstimate()

  return available<PersistentStorage>({
    persisted,
    estimate,
    canRequestSilently,
    async requestPersistence() {
      const current = await readPersisted()
      if (current || !canRequestSilently || typeof manager.persist !== "function") return current
      try {
        const granted = await manager.persist()
        persisted.set(granted)
        return granted
      } catch {
        return current
      }
    },
    refreshEstimate,
  })
}
