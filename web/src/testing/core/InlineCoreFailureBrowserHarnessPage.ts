import { AuthStore } from "@inline/client/core"
import { userId } from "@inline/ids"
import type { InlineCoreSnapshot } from "../../inline/core/InlineCoreProtocol"
import type { InlineCoreRendererClient } from "../../inline/core/InlineCoreRendererClient"
import { createInlineCoreRendererClient } from "../../inline/core/createInlineCoreRendererClient"

export type InlineCoreFailureBrowserHarness = {
  connect: () => Promise<string>
  saveDraft: (text: string) => Promise<void>
  loadDraft: () => Promise<string | undefined>
  waitForFailure: () => Promise<InlineCoreSnapshot>
  startAfterFailure: () => Promise<{ code?: string; message: string }>
  recover: () => Promise<string>
  clearDraft: () => Promise<void>
  errors: () => string[]
  detach: () => void
}

declare global {
  interface Window {
    inlineCoreFailureHarness: InlineCoreFailureBrowserHarness
  }
}

const accountId = userId("9223372036854774000")
const draftPeer = {
  peerKind: "user" as const,
  peerUserId: userId("9223372036854773999"),
}
const auth = new AuthStore({ persistence: "memory" })
auth.login({
  token: "browser-core-failure-smoke-token",
  userId: accountId,
})

// The smoke owns a synthetic account and must never open a production socket.
Object.defineProperty(window.navigator, "onLine", {
  configurable: true,
  value: false,
})

let core: InlineCoreRendererClient | undefined
const runtimeErrors: string[] = []

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

const activeCore = () => {
  if (!core) throw new Error("Inline core failure harness is not connected")
  return core
}

const waitForSnapshot = async (
  predicate: (snapshot: InlineCoreSnapshot) => boolean,
  label: string,
) => {
  const client = activeCore()
  const current = client.getSnapshot()
  if (predicate(current)) return current
  return new Promise<InlineCoreSnapshot>((resolve, reject) => {
    const timeout = window.setTimeout(() => {
      unsubscribe()
      reject(new Error(`Timed out waiting for ${label}`))
    }, 15_000)
    const unsubscribe = client.subscribe(() => {
      const snapshot = client.getSnapshot()
      if (!predicate(snapshot)) return
      window.clearTimeout(timeout)
      unsubscribe()
      resolve(snapshot)
    })
  })
}

const makeCore = () =>
  createInlineCoreRendererClient({
    auth,
    session: {
      token: auth.getToken()!,
      userId: accountId,
    },
  })

const connect = async () => {
  core = makeCore()
  await core.start()
  const snapshot = await waitForSnapshot(
    (value) => value.cacheReady,
    "Inline cache readiness",
  )
  return snapshot.ownerId
}

window.inlineCoreFailureHarness = {
  connect,
  saveDraft: (text) =>
    activeCore().messageDrafts.update(draftPeer, text),
  loadDraft: async () =>
    (await activeCore().messageDrafts.load(draftPeer))?.text,
  waitForFailure: () =>
    waitForSnapshot(
      (snapshot) =>
        snapshot.blockingFailure?.recoveryAction === "reload",
      "terminal Inline core failure",
    ),
  startAfterFailure: async () => {
    try {
      await activeCore().start()
      return { message: "unexpected success" }
    } catch (error) {
      return {
        code:
          error instanceof Error && "code" in error
            ? String(error.code)
            : undefined,
        message:
          error instanceof Error ? error.message : String(error),
      }
    }
  },
  recover: async () => {
    activeCore().detach()
    core = makeCore()
    await core.start()
    const snapshot = await waitForSnapshot(
      (value) => value.cacheReady,
      "recovered Inline cache readiness",
    )
    return snapshot.ownerId
  },
  clearDraft: () => activeCore().messageDrafts.clear(draftPeer),
  errors: () => runtimeErrors.slice(),
  detach: () => {
    core?.detach()
    core = undefined
  },
}
