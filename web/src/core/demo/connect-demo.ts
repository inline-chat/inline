/**
 * Connects this UI context to a demo account: the production core in its
 * own worker, against a simulated server in that worker. Same shape as
 * `connectAccount` (plus `demo`, the control channel), so a view can swap
 * one for the other. Development only; `main.tsx` never imports this.
 */
import type { UserID } from "@inline/ids"
import { browserPlatform, connectCore, watchBrowserSignals, workerCore } from "@inline/link"
import { browserScheduler, createStoreClient } from "@inline/reactive"
import {
  DEFAULT_DEMO_CONFIG,
  DEMO_USER_ID,
  demoNames,
  parseDemoConfig,
  type DemoConfig,
} from "../../../packages/client/src/testing/demo-protocol"
import { trustedScriptUrl } from "../../sw/trusted-script-url"
import { BUILD_ID } from "../build"
import type { AccountConnection } from "../connect"
import { connectDemoControl, type DemoControl } from "./control"
// `new Worker` is a Trusted Types sink under the production content policy.
import demoWorkerUrl from "./demo.worker.ts?worker&url"

export type DemoAccountOptions = Partial<DemoConfig>

export type DemoAccountConnection = AccountConnection & {
  /** The demo's fixed user. */
  userId: UserID
  config: DemoConfig
  /** Drives the simulated world. */
  demo: DemoControl
}

export const connectDemoAccount = (options: DemoAccountOptions = {}): DemoAccountConnection => {
  const config = parseDemoConfig({ ...DEFAULT_DEMO_CONFIG, ...options })
  const names = demoNames(config)
  const userId = DEMO_USER_ID as UserID
  const core = connectCore({
    ...browserPlatform(),
    // Locks and channels keyed by the demo's own origin: never a real account's.
    account: { origin: names.origin, userId },
    buildId: BUILD_ID,
    startCore: workerCore(
      () =>
        new Worker(trustedScriptUrl(demoWorkerUrl) as string | URL, {
          type: "module",
          name: JSON.stringify(config),
        }),
    ),
  })
  const stopSignals = watchBrowserSignals(core)
  const client = createStoreClient({ endpoint: core, scheduler: browserScheduler() })
  const demo = connectDemoControl(names.channel)
  core.post({ kind: "session", action: "start", session: { userId, token: "demo" } })
  return {
    core,
    client,
    userId,
    config,
    demo,
    close: () => {
      demo.close()
      stopSignals()
      client.dispose()
      core.close()
    },
  }
}
