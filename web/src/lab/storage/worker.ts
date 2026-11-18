/// <reference lib="webworker" />
import type { UserID } from "@inline/ids"
import {
  createOpfsSqlitePersistenceStore,
  eraseOpfsSqliteReplica,
  InlineSqliteUnavailableError,
} from "@inline/client/sqlite"

type Request =
  | { id: number; cmd: "open"; account: string }
  | { id: number; cmd: "set"; value: string }
  | { id: number; cmd: "get" }
  | { id: number; cmd: "close" }
  | { id: number; cmd: "erase"; account: string }

const NAMESPACE = "storage-lab"
let store: ReturnType<typeof createOpfsSqlitePersistenceStore> | undefined

const handle = async (request: Request): Promise<unknown> => {
  switch (request.cmd) {
    case "open": {
      store = createOpfsSqlitePersistenceStore(request.account as UserID, undefined, {
        namespace: NAMESPACE,
      })
      const started = performance.now()
      await store.open()
      return { openedInMs: Math.round(performance.now() - started) }
    }
    case "set":
      await store?.setReplicaMetadata("probe", request.value)
      return true
    case "get":
      return (await store?.getReplicaMetadata("probe")) ?? null
    case "close":
      await store?.close()
      store = undefined
      return true
    case "erase":
      await eraseOpfsSqliteReplica(request.account as UserID, { namespace: NAMESPACE })
      return true
  }
}

self.addEventListener("message", (event: MessageEvent<Request>) => {
  const request = event.data
  handle(request).then(
    (value) => self.postMessage({ id: request.id, ok: true, value }),
    (error: unknown) =>
      self.postMessage({
        id: request.id,
        ok: false,
        reason: error instanceof InlineSqliteUnavailableError ? error.reason : "other",
        message: error instanceof Error ? error.message : String(error),
        cause:
          error instanceof Error && error.cause instanceof Error
            ? `${error.cause.name}: ${error.cause.message}`
            : undefined,
      }),
  )
})
