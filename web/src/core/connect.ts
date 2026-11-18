/**
 * Connects this UI context to the account's core. Whether the core runs in
 * this tab's worker or in another tab that leads is link's business.
 */
import type { UserID } from "@inline/ids"
import { getServerUrl } from "@inline/config"
import {
  browserPlatform,
  connectCore,
  watchBrowserSignals,
  workerCore,
  type LinkedCore,
} from "@inline/link"
import { browserScheduler, createStoreClient, type StoreClient } from "@inline/reactive"
import { trustedScriptUrl } from "../sw/trusted-script-url"
import { BUILD_ID } from "./build"
// The bundled worker's URL. `new Worker` is a Trusted Types sink in production.
import coreWorkerUrl from "./core.worker.ts?worker&url"

export type AccountConnection = {
  core: LinkedCore
  client: StoreClient
  /** Stops forwarding signals, releases the store and leaves the account's election. */
  close(): void
}

const serverOrigin = () => {
  try {
    return new URL(getServerUrl()).origin
  } catch {
    return "default"
  }
}

export const connectAccount = (userId: UserID): AccountConnection => {
  const core = connectCore({
    ...browserPlatform(),
    account: { origin: serverOrigin(), userId },
    buildId: BUILD_ID,
    startCore: workerCore(
      () => new Worker(trustedScriptUrl(coreWorkerUrl) as string | URL, { type: "module" }),
    ),
  })
  const stopSignals = watchBrowserSignals(core)
  const client = createStoreClient({
    endpoint: core,
    scheduler: browserScheduler(),
    onBatch: (info) => {
      // Marks are only recorded when a performance run asked for them (the
      // performance lab sets the flag); the mark buffer is unbounded.
      if ((globalThis as { __inlinePerfMarks?: boolean }).__inlinePerfMarks !== true) return
      performance.mark("inline.patch.apply", { detail: info })
    },
  })
  return {
    core,
    client,
    close: () => {
      stopSignals()
      client.dispose()
      core.close()
    },
  }
}
