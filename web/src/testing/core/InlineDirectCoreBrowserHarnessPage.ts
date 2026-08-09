import { AuthStore } from "@inline/client/core"
import { userId } from "@inline/ids"
import { Log } from "@inline/log"
import { InlineAccountCore } from "../../inline/core/InlineAccountCore"
import {
  createInlineCoreAccountOwnershipAcquirer,
  type InlineCoreLockManager,
} from "../../inline/core/InlineCoreAccountOwnership"
import type { InlineCoreSnapshot } from "../../inline/core/InlineCoreProtocol"

export type InlineDirectCoreBrowserHarness = {
  connect: () => Promise<InlineCoreSnapshot>
  retry: () => Promise<InlineCoreSnapshot>
  saveDraft: (text: string) => Promise<void>
  loadDraft: () => Promise<string | undefined>
  clearDraft: () => Promise<void>
  stats: () => { storageOpens: number; realtimeStarts: number }
  errors: () => string[]
  detach: () => Promise<void>
}

declare global {
  interface Window {
    inlineDirectCoreHarness: InlineDirectCoreBrowserHarness
  }
}

const accountId = userId("9223372036854775000")
const draftPeer = {
  peerKind: "user" as const,
  peerUserId: userId("9223372036854774999"),
}
const auth = new AuthStore({ persistence: "memory" })
await auth.login({
  token: "browser-direct-core-smoke-token",
  userId: accountId,
})

const acquireOwnership = createInlineCoreAccountOwnershipAcquirer(
  navigator.locks as unknown as InlineCoreLockManager,
)
const runtimeErrors: string[] = []
let core: InlineAccountCore | undefined
let storageOpens = 0
let realtimeStarts = 0

window.addEventListener("error", (event) => {
  runtimeErrors.push(
    event.error instanceof Error
      ? event.error.stack ?? event.error.message
      : event.message,
  )
})
window.addEventListener("unhandledrejection", (event) => {
  runtimeErrors.push(
    event.reason instanceof Error
      ? event.reason.stack ?? event.reason.message
      : String(event.reason),
  )
})

const makeCore = () => {
  const next = new InlineAccountCore(accountId, {
    auth,
    observeBrowserLifecycle: false,
    acquireAccountOwnership: acquireOwnership,
    logger: new Log("BrowserHarness", { sink: false }),
  })
  const openPersistence = next.db.openPersistence.bind(next.db)
  next.db.openPersistence = async () => {
    storageOpens += 1
    await openPersistence()
  }
  next.realtime.start = async () => {
    realtimeStarts += 1
  }
  next.realtime.query = async () => undefined
  return next
}

const activeCore = () => {
  if (!core) throw new Error("Inline direct core harness is not connected")
  return core
}

const connect = async () => {
  if (core) throw new Error("Inline direct core harness is already connected")
  core = makeCore()
  await core.start()
  return core.getSnapshot()
}

window.inlineDirectCoreHarness = {
  connect,
  retry: async () => {
    await core?.stop()
    core = undefined
    return await connect()
  },
  saveDraft: (text) => activeCore().messageDrafts.update(draftPeer, text),
  loadDraft: async () =>
    (await activeCore().messageDrafts.load(draftPeer))?.text,
  clearDraft: () => activeCore().messageDrafts.clear(draftPeer),
  stats: () => ({ storageOpens, realtimeStarts }),
  errors: () => runtimeErrors.slice(),
  detach: async () => {
    await core?.stop()
    core = undefined
  },
}
