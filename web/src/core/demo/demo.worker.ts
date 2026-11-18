/// <reference lib="webworker" />
/**
 * The demo account's core worker: `core.worker.ts` with the wire replaced.
 * The real `CoreHost` (replica, realtime client, sync, outbox, queries)
 * talks to a `DemoWorld` in this worker through a scripted transport; the
 * world holds a seeded, lazily generated server model and answers control
 * commands on the demo's own `BroadcastChannel`.
 *
 * Configuration comes in the worker's name (see `connect-demo.ts`). Storage
 * and channel names are the demo's own (`demoNames`), never a real
 * account's. Development only: nothing in `main.tsx` reaches this file.
 */
import { CoreHost, openOpfsHostStorage, type HostStorage } from "@inline/client/host"
import { createSqliteMemoryPersistenceStore } from "@inline/client/sqlite"
import type { UserID } from "@inline/ids"
import { Log } from "@inline/log"
import { serveCore } from "@inline/link"
import {
  demoNames,
  isDemoCommand,
  parseDemoConfig,
  type DemoEvent,
} from "../../../packages/client/src/testing/demo-protocol"
import { DemoWorld } from "../../../packages/client/src/testing/demo-world"
import { BUILD_ID } from "../build"
import { opfsWorldStore } from "./opfs-world-store"

const config = parseDemoConfig(self.name)
const names = demoNames(config)
const log = new Log("Demo", { level: "info" })

const memoryStorage = (): HostStorage => ({
  store: createSqliteMemoryPersistenceStore(),
  kind: "memory",
  erase: async () => undefined,
})

serveCore(self, () => {
  const channel = new BroadcastChannel(names.channel)
  const post = (event: DemoEvent) => {
    try {
      channel.postMessage(event)
    } catch (error) {
      log.warn("channel.post.failed", { error })
    }
  }
  let host: CoreHost | undefined
  const world = new DemoWorld({
    seed: config.seed,
    scale: config.scale,
    storage: config.storage,
    ...(config.storage === "opfs" ? { store: opfsWorldStore(names.namespace) } : {}),
    logger: log,
    // Other members type now and then, as the scale's preset says (`activity` control to change it).
    activity: "preset",
    onEvent: post,
    // Back online: the connection retries now instead of after its backoff.
    onWake: () => host?.post({ kind: "signal", signal: { kind: "wake" } }),
  })
  host = new CoreHost({
    buildId: BUILD_ID,
    logger: log.withScope("Core"),
    openStorage: (userId: UserID) =>
      config.storage === "opfs"
        ? openOpfsHostStorage(userId, { namespace: names.namespace })
        : memoryStorage(),
    createTransport: () => world.transport,
    media: {
      // The demo's own media directory, never a real account's.
      accountKey: () => names.namespace,
      // Demo files carry no URLs: every byte comes over the simulated socket
      // (`GET_FILE_PART`). Nothing in the demo may reach the network.
      fetch: async (input) => {
        log.warn("media.fetch.refused", { url: String(input) })
        throw new TypeError("The demo core never fetches from the network")
      },
    },
  })
  const onCommand = (event: MessageEvent<unknown>) => {
    const command = event.data
    // Other contexts' events (status, results) share the channel: ignore them.
    if (!isDemoCommand(command)) return
    void world.handle(command).then(post)
  }
  channel.addEventListener("message", onCommand)
  world.emitStatus()

  const running = host
  return {
    open: () => running.openContext(),
    close: async () => {
      channel.removeEventListener("message", onCommand)
      // The core first, so its last requests are answered; then the server.
      await running.close()
      await world.dispose()
      channel.close()
    },
  }
})
