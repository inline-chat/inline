/**
 * The boot sweep's place in the boot path (`src/core/account-storage-sweep.ts`,
 * security.md "Session and storage"): queued once per page on the warm-up
 * lane, after the first paint, with its module loaded then. Never in the demo
 * (its accounts live in the demo's own namespace, and an in-memory auth store
 * would name no owners for this server's), and never from a lab page (labs do
 * not run `boot.ts`).
 */

import type { Log } from "@inline/log"
import type { BrowserSweepOptions } from "../core/account-storage-sweep"
import { chunkImporters } from "./view-chunks"

export type StorageSweepQueue = {
  /** The warm-up queue (`Warmup.add`). */
  readonly warmup: { add(task: () => Promise<unknown> | unknown): void }
  /** The page booted the demo. */
  readonly demo: boolean
  readonly authStore: BrowserSweepOptions["authStore"]
  readonly log?: Log
  /** The sweep's module (default: its chunk). */
  readonly load?: () => Promise<Pick<typeof import("../core/account-storage-sweep"), "sweepBrowserAccountStorage">>
}

/** Queue the sweep unless this is the demo. Returns whether it was queued. */
export const queueAccountStorageSweep = (options: StorageSweepQueue): boolean => {
  if (options.demo) return false
  const load = options.load ?? chunkImporters.storageSweep
  options.warmup.add(async () => {
    const { sweepBrowserAccountStorage } = await load()
    await sweepBrowserAccountStorage({ authStore: options.authStore, ...(options.log ? { log: options.log } : {}) })
  })
  return true
}
