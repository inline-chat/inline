import {
  DbObjectKind,
  messageDraftKey,
} from "@inline/client/core"
import { userId } from "@inline/ids"
import {
  INLINE_CORE_PROTOCOL_VERSION,
  type InlineCoreClientMessage,
  type InlineCoreHostMessage,
} from "../../inline/core/InlineCoreProtocol"

type HarnessClient = {
  worker: SharedWorker
  ownerId: string
  messages: InlineCoreHostMessage[]
}

export type InlineCoreOwnerBrowserHarness = {
  connect: (clientId: string) => Promise<string>
  connectDifferentGeneration: (
    clientId: string,
    generation: string,
  ) => Promise<string>
  waitForCacheReady: (clientId: string) => Promise<string>
  requestProjection: (clientId: string) => Promise<number>
  updateDraft: (clientId: string, text: string) => Promise<void>
  loadDraftText: (clientId: string) => Promise<string | undefined>
  clearDraft: (clientId: string) => Promise<void>
  detach: (clientId: string) => void
  messages: (clientId: string) => InlineCoreHostMessage[]
  errors: () => string[]
}

declare global {
  interface Window {
    inlineCoreOwnerHarness: InlineCoreOwnerBrowserHarness
  }
}

const accountId = userId("9223372036854775000")
const draftPeer = {
  peerKind: "user" as const,
  peerUserId: userId("9223372036854774999"),
}
const draftId = messageDraftKey(draftPeer)
const clients = new Map<string, HarnessClient>()
const runtimeErrors: string[] = []
let nextRequestSequence = 0
const hasSnapshot = (
  message: InlineCoreHostMessage,
): message is Extract<
  InlineCoreHostMessage,
  { type: "inlineCoreReady" | "inlineCoreSnapshot" }
> =>
  message.type === "inlineCoreReady" ||
  message.type === "inlineCoreSnapshot"

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

const connect = (
  clientId: string,
  workerName = `inline-core-v${INLINE_CORE_PROTOCOL_VERSION}`,
) =>
  new Promise<string>((resolve, reject) => {
    if (clients.has(clientId)) {
      reject(new Error(`Inline core harness client ${clientId} already exists`))
      return
    }
    const worker = new SharedWorker(
      new URL(
        "../../inline/core/InlineCore.shared-worker.ts",
        import.meta.url,
      ),
      {
        type: "module",
        name: workerName,
      },
    )
    const timeout = window.setTimeout(() => {
      worker.port.close()
      reject(new Error("Inline core SharedWorker handshake timed out"))
    }, 5_000)
    const messages: InlineCoreHostMessage[] = []
    const handleMessage = (event: MessageEvent<unknown>) => {
      const message = event.data as InlineCoreHostMessage
      messages.push(message)
      if (message.type === "inlineCoreError") {
        window.clearTimeout(timeout)
        worker.port.close()
        reject(
          new Error(
            `Inline core SharedWorker rejected the harness: ${message.code}: ${message.message}`,
          ),
        )
        return
      }
      if (message.type !== "inlineCoreReady") return
      window.clearTimeout(timeout)
      clients.set(clientId, {
        worker,
        ownerId: message.identity.ownerId,
        messages,
      })
      resolve(message.identity.ownerId)
    }
    worker.addEventListener("error", (event) => {
      window.clearTimeout(timeout)
      reject(
        new Error(
          event instanceof ErrorEvent && event.message
            ? event.message
            : "Inline core SharedWorker failed to load",
        ),
      )
    })
    worker.port.addEventListener("message", handleMessage)
    worker.port.start()
    worker.port.postMessage({
      type: "inlineCoreHello",
      protocolVersion: INLINE_CORE_PROTOCOL_VERSION,
      clientId,
      accountId,
      session: {
        token: "browser-owner-smoke-token",
        userId: accountId,
      },
      // The ownership smoke must remain local and must not open a production
      // websocket with its deliberately synthetic session.
      lifecycle: { visible: true, online: false },
    })
  })

const client = (clientId: string) => {
  const value = clients.get(clientId)
  if (!value) {
    throw new Error(`Unknown Inline core harness client ${clientId}`)
  }
  return value
}

const request = (
  clientId: string,
  makeMessage: (
    requestId: string,
  ) => Extract<InlineCoreClientMessage, { requestId: string }>,
) =>
  new Promise<void>((resolve, reject) => {
    const connected = client(clientId)
    const requestId = `browser-owner-${++nextRequestSequence}`
    const timeout = window.setTimeout(() => {
      connected.worker.port.removeEventListener("message", listener)
      reject(new Error(`Inline core request ${requestId} timed out`))
    }, 2_000)
    const listener = (event: MessageEvent<unknown>) => {
      const message = event.data as InlineCoreHostMessage
      if (
        (message.type !== "inlineCoreResult" &&
          message.type !== "inlineCoreError") ||
        message.requestId !== requestId
      ) {
        return
      }
      window.clearTimeout(timeout)
      connected.worker.port.removeEventListener("message", listener)
      if (message.type === "inlineCoreError") {
        reject(new Error(message.message))
      } else {
        resolve()
      }
    }
    connected.worker.port.addEventListener("message", listener)
    connected.worker.port.postMessage(makeMessage(requestId))
  })

const projection = (clientId: string) =>
  new Promise<Extract<InlineCoreHostMessage, { type: "inlineCoreProjection" }>["projection"]>(
    (resolve, reject) => {
      const connected = client(clientId)
      const timeout = window.setTimeout(() => {
        connected.worker.port.removeEventListener("message", listener)
        reject(new Error("Inline core projection resync timed out"))
      }, 2_000)
      const listener = (event: MessageEvent<unknown>) => {
        const message = event.data as InlineCoreHostMessage
        if (message.type !== "inlineCoreProjection") return
        window.clearTimeout(timeout)
        connected.worker.port.removeEventListener("message", listener)
        resolve(message.projection)
      }
      connected.worker.port.addEventListener("message", listener)
      connected.worker.port.postMessage({ type: "inlineCoreResync" })
    },
  )

window.inlineCoreOwnerHarness = {
  connect,
  connectDifferentGeneration: (clientId, generation) =>
    new Promise<string>((resolve) => {
      const worker = new SharedWorker(
        new URL(
          "../../inline/core/InlineCore.shared-worker.ts",
          import.meta.url,
        ),
        {
          type: "module",
          name: `inline-core-v${INLINE_CORE_PROTOCOL_VERSION}-${generation}`,
        },
      )
      const timeout = window.setTimeout(() => {
        worker.port.close()
        resolve("timed-out")
      }, 5_000)
      worker.port.addEventListener("message", (event) => {
        const message = event.data as InlineCoreHostMessage
        if (
          message.type !== "inlineCoreError" &&
          message.type !== "inlineCoreReady"
        ) {
          return
        }
        window.clearTimeout(timeout)
        worker.port.close()
        resolve(
          message.type === "inlineCoreError"
            ? `${message.code}: ${message.message}`
            : "opened",
        )
      })
      worker.port.start()
      worker.port.postMessage({
        type: "inlineCoreHello",
        protocolVersion: INLINE_CORE_PROTOCOL_VERSION,
        clientId,
        accountId,
        session: {
          token: "browser-owner-smoke-token",
          userId: accountId,
        },
        lifecycle: { visible: true, online: false },
      })
    }),
  waitForCacheReady: (clientId) =>
    new Promise<string>((resolve, reject) => {
      const client = clients.get(clientId)
      if (!client) {
        reject(new Error(`Unknown Inline core harness client ${clientId}`))
        return
      }
      const readySnapshot = client.messages.find(
        (message) =>
          hasSnapshot(message) &&
          message.snapshot.cacheReady,
      )
      if (readySnapshot && hasSnapshot(readySnapshot)) {
        resolve(readySnapshot.snapshot.phase)
        return
      }
      const timeout = window.setTimeout(() => {
        client.worker.port.removeEventListener("message", listener)
        reject(new Error("Inline core cache readiness timed out"))
      }, 5_000)
      const listener = (event: MessageEvent<unknown>) => {
        const message = event.data as InlineCoreHostMessage
        if (
          !hasSnapshot(message) ||
          !message.snapshot.cacheReady
        ) {
          return
        }
        window.clearTimeout(timeout)
        client.worker.port.removeEventListener("message", listener)
        resolve(message.snapshot.phase)
      }
      client.worker.port.addEventListener("message", listener)
    }),
  requestProjection: async (clientId) =>
    (await projection(clientId)).revision,
  updateDraft: (clientId, text) =>
    request(clientId, (requestId) => ({
      type: "inlineCoreUpdateMessageDraft",
      requestId,
      peer: draftPeer,
      text,
    })),
  loadDraftText: async (clientId) => {
    await request(clientId, (requestId) => ({
      type: "inlineCoreLoadMessageDraft",
      requestId,
      peer: draftPeer,
    }))
    const snapshot = await projection(clientId)
    const draft = snapshot.objects.find(
      (object) =>
        object.kind === DbObjectKind.MessageDraft &&
        object.id === draftId,
    )
    return draft?.kind === DbObjectKind.MessageDraft
      ? draft.text
      : undefined
  },
  clearDraft: (clientId) =>
    request(clientId, (requestId) => ({
      type: "inlineCoreClearMessageDraft",
      requestId,
      peer: draftPeer,
    })),
  detach: (clientId) => {
    const client = clients.get(clientId)
    if (!client) return
    clients.delete(clientId)
    client.worker.port.postMessage({ type: "inlineCoreDetach" })
    client.worker.port.close()
  },
  messages: (clientId) =>
    clients.get(clientId)?.messages.slice() ?? [],
  errors: () => runtimeErrors.slice(),
}
