import {
  Method,
  RealtimeV3Request,
  RealtimeV3Response,
  RealtimeV3Update,
  RpcError_Code,
  type AuthBeginRequest,
  type AuthBeginResult,
  type AuthBeginBrowserRequest,
  type AuthBeginBrowserResult,
  type AuthBrowserStatusRequest,
  type AuthBrowserStatusResult,
  type AuthCompleteRequest,
  type AuthCompleteResult,
  type InputPeer,
  type RpcCall,
  type ServerProtocolMessage,
} from "@inline-chat/protocol/core"
import {
  InlineProtocolApplicationOutputOverloaded,
  type ServerApplicationAuthorization,
  type ServerApplicationDispatcher,
  type ServerAuthorizationKeyRepository,
} from "@inline-chat/protocol/server"
/*
 * The output-capacity error crosses the application adapter unchanged so the
 * secure-session owner can classify an already-started mutation as uncertain.
 */
import { handleRpcCall } from "@in/server/realtime/handlers/_rpc"
import { toRealtimeRpcError } from "@in/server/realtime/rpcErrorBoundary"
import type { RealtimeRequestMetadata } from "@in/server/realtime/types"
import { Log } from "@in/server/utils/log"
import { InlineError } from "@in/server/types/errors"

const log = new Log("InlineProtocol.V3.Application")

export type InlineProtocolApplicationContext = {
  authorization: ServerApplicationAuthorization
  metadata?: RealtimeRequestMetadata
  signal?: AbortSignal
}

export interface InlineProtocolApplicationOperations {
  authBegin(input: AuthBeginRequest, context: InlineProtocolApplicationContext): Promise<AuthBeginResult>
  authComplete(input: AuthCompleteRequest, context: InlineProtocolApplicationContext): Promise<AuthCompleteResult>
  authBeginBrowser(input: AuthBeginBrowserRequest, context: InlineProtocolApplicationContext): Promise<AuthBeginBrowserResult>
  authBrowserStatus(input: AuthBrowserStatusRequest, context: InlineProtocolApplicationContext): Promise<AuthBrowserStatusResult>
}

const unauthorizedResponse = (): Uint8Array => RealtimeV3Response.toBinary({
  body: {
    oneofKind: "rpcError",
    rpcError: {
      reqMsgId: 0n,
      errorCode: RpcError_Code.UNAUTHENTICATED,
      message: "Unauthenticated",
      code: 401,
    },
  },
})

const errorResponse = (error: unknown): Uint8Array => {
  const rpc = toRealtimeRpcError(error)
  if (rpc.codeNumber >= 500) {
    log.error("Inline Protocol application request failed", error)
  }
  return RealtimeV3Response.toBinary({
    body: {
      oneofKind: "rpcError",
      rpcError: {
        reqMsgId: 0n,
        errorCode: rpc.code,
        message: rpc.message,
        code: rpc.codeNumber,
      },
    },
  })
}

const freshRequestIdRequiredResponse = (): Uint8Array => RealtimeV3Response.toBinary({
  body: {
    oneofKind: "rpcError",
    rpcError: {
      reqMsgId: 0n,
      errorCode: RpcError_Code.RATE_LIMIT,
      message: "Retry getFilePart with a fresh request ID",
      code: 429,
    },
  },
})

const sendV3Update = (
  message: ServerProtocolMessage,
  sendUpdate: (payload: Uint8Array) => void,
): void => {
  if (message.body.oneofKind !== "message") return
  sendUpdate(RealtimeV3Update.toBinary({ message: message.body.message }))
}

const peerLane = (peer: InputPeer | undefined): string | undefined => {
  switch (peer?.type.oneofKind) {
    case "chat": return `chat:${peer.type.chat.chatId}`
    case "user": return `user:${peer.type.user.userId}`
    default: return undefined
  }
}

export const inlineProtocolRpcExecutionLane = (rpc: RpcCall): string | undefined => {
  switch (rpc.input.oneofKind) {
    case "sendMessage": return peerLane(rpc.input.sendMessage.peerId)
    case "editMessage": return peerLane(rpc.input.editMessage.peerId)
    case "deleteMessages": return peerLane(rpc.input.deleteMessages.peerId)
    case "deleteMessageAttachment": return peerLane(rpc.input.deleteMessageAttachment.peerId)
    case "forwardMessages": return peerLane(rpc.input.forwardMessages.toPeerId)
    case "addReaction": return peerLane(rpc.input.addReaction.peerId)
    case "deleteReaction": return peerLane(rpc.input.deleteReaction.peerId)
    case "pinMessage": return peerLane(rpc.input.pinMessage.peerId)
    case "deleteChat": return peerLane(rpc.input.deleteChat.peerId)
    case "markAsUnread": return peerLane(rpc.input.markAsUnread.peerId)
    case "readMessages": return peerLane(rpc.input.readMessages.peerId)
    case "updateDialogNotificationSettings": {
      return peerLane(rpc.input.updateDialogNotificationSettings.peerId)
    }
    case "updateDialogFollowMode": return peerLane(rpc.input.updateDialogFollowMode.peerId)
    case "showInChatList": return peerLane(rpc.input.showInChatList.peerId)
    case "updateDialogOpen": return peerLane(rpc.input.updateDialogOpen.peerId)
    case "updateDialogOrder": return peerLane(rpc.input.updateDialogOrder.peerId)
    case "updateDialogArchived": return peerLane(rpc.input.updateDialogArchived.peerId)
    case "collapseHistory": return peerLane(rpc.input.collapseHistory.peerId)
    case "connectAgentSession": return peerLane(rpc.input.connectAgentSession.peerId)
    case "syncAgentSessionMessages": {
      return `agent-session:${rpc.input.syncAgentSessionMessages.agentSessionId}`
    }
    case "clearChatHistory": {
      const target = rpc.input.clearChatHistory.target
      if (target.oneofKind === "peerId") return peerLane(target.peerId)
      if (target.oneofKind === "spaceId") return `space:${target.spaceId}`
      return undefined
    }
    case "addChatParticipant": return `chat:${rpc.input.addChatParticipant.chatId}`
    case "removeChatParticipant": return `chat:${rpc.input.removeChatParticipant.chatId}`
    case "updateChatVisibility": return `chat:${rpc.input.updateChatVisibility.chatId}`
    case "updateChatInfo": return `chat:${rpc.input.updateChatInfo.chatId}`
    case "moveThread": return `chat:${rpc.input.moveThread.chatId}`
    case "createSubthread": return `chat:${rpc.input.createSubthread.parentChatId}`
    case "deleteMember": return `space:${rpc.input.deleteMember.spaceId}`
    case "updateMemberAccess": return `space:${rpc.input.updateMemberAccess.spaceId}`
    case "toggleSpaceGrid": return `space:${rpc.input.toggleSpaceGrid.spaceId}`
    case "updateUserSettings": return "account:settings"
    default: return undefined
  }
}

export class InlineProtocolApplicationLanes {
  readonly #tails = new Map<string, Promise<void>>()

  async run<T>(key: string | undefined, signal: AbortSignal, operation: () => Promise<T>): Promise<T> {
    if (!key) return await operation()
    const previous = this.#tails.get(key) ?? Promise.resolve()
    let release!: () => void
    const current = new Promise<void>((resolve) => { release = resolve })
    const tail = previous.catch(() => {}).then(() => current)
    this.#tails.set(key, tail)
    try {
      await waitForLane(previous, signal)
      return await operation()
    } finally {
      release()
      // An aborted waiter must leave its placeholder in the chain until the
      // previous owner has actually finished. Deleting it immediately would
      // let a later same-key operation bypass the still-running owner.
      void tail.then(() => {
        if (this.#tails.get(key) === tail) this.#tails.delete(key)
      })
    }
  }
}

const waitForLane = async (previous: Promise<void>, signal: AbortSignal): Promise<void> => {
  if (signal.aborted) throw signal.reason ?? new DOMException("Aborted", "AbortError")
  let onAbort!: () => void
  const aborted = new Promise<never>((_, reject) => {
    onAbort = () => reject(signal.reason ?? new DOMException("Aborted", "AbortError"))
    signal.addEventListener("abort", onAbort, { once: true })
  })
  try {
    await Promise.race([previous.catch(() => {}), aborted])
  } finally {
    signal.removeEventListener("abort", onAbort)
  }
}

export const makeInlineProtocolApplicationDispatcher = (input: {
  operations: InlineProtocolApplicationOperations
  authorizationKeys: Pick<ServerAuthorizationKeyRepository, "load">
  connectionId: string
  metadata?: RealtimeRequestMetadata
  onAuthorized?: (authorization: ServerApplicationAuthorization) => void
}): ServerApplicationDispatcher => {
  const lanes = new InlineProtocolApplicationLanes()
  return {
    dispatch: async ({ payload, authorization, signal, markExecutionStarted, sendUpdate }) => {
      let request
      try {
        request = RealtimeV3Request.fromBinary(payload)
      } catch (error) {
        if (error instanceof InlineProtocolApplicationOutputOverloaded) throw error
        // The secure-session owner classifies an aborted application as either
        // rejected-before-execution or commit-unknown. Turning the abort into a
        // normal RPC error here would make the timed-out result replayable as a
        // definitive application failure even though execution may have begun.
        if (signal.aborted) throw signal.reason ?? error
        return { kind: "result", payload: errorResponse(error) }
      }
      const context = { authorization, metadata: input.metadata, signal }
      try {
        if (authorization.permanent && authorization.userId === undefined) {
          if (request.body.oneofKind === "authBegin") {
            markExecutionStarted()
            const result = await input.operations.authBegin(request.body.authBegin, context)
            return {
              kind: "result",
              payload: RealtimeV3Response.toBinary({
                body: { oneofKind: "authBegin", authBegin: result },
              }),
            }
          }
          if (request.body.oneofKind === "authComplete") {
            markExecutionStarted()
            const result = await input.operations.authComplete(request.body.authComplete, context)
            return {
              kind: "result",
              payload: RealtimeV3Response.toBinary({
                body: { oneofKind: "authComplete", authComplete: result },
              }),
            }
          }
          if (request.body.oneofKind === "authBeginBrowser") {
            markExecutionStarted()
            const result = await input.operations.authBeginBrowser(request.body.authBeginBrowser, context)
            return {
              kind: "result",
              payload: RealtimeV3Response.toBinary({
                body: { oneofKind: "authBeginBrowser", authBeginBrowser: result },
              }),
            }
          }
          if (request.body.oneofKind === "authBrowserStatus") {
            const result = await input.operations.authBrowserStatus(request.body.authBrowserStatus, context)
            return {
              kind: "result",
              payload: RealtimeV3Response.toBinary({
                body: { oneofKind: "authBrowserStatus", authBrowserStatus: result },
              }),
            }
          }
          return { kind: "result", payload: unauthorizedResponse() }
        }

        if (!authorization.temporaryBound || authorization.userId === undefined ||
            authorization.accountSessionId === undefined) {
          return { kind: "result", payload: unauthorizedResponse() }
        }
        if (request.body.oneofKind === "rpc") {
          const rpc = request.body.rpc
          const result = await lanes.run(inlineProtocolRpcExecutionLane(rpc), signal, async () => {
            // Admission may precede a long resource-lane wait. Revalidate the
            // same binding before entering application-owned execution.
            const current = await input.authorizationKeys.load(authorization.authKeyId)
            if (signal.aborted) throw signal.reason ?? new DOMException("Aborted", "AbortError")
            if (!current?.temporary || !current.binding || !authorization.permanentAuthKeyId ||
                current.binding.userId !== authorization.userId ||
                current.binding.accountSessionId !== authorization.accountSessionId ||
                !Buffer.from(current.binding.permanentAuthKeyId).equals(authorization.permanentAuthKeyId)) {
              throw new InlineError(InlineError.ApiError.UNAUTHORIZED)
            }
            input.onAuthorized?.(authorization)
            markExecutionStarted()
            return await handleRpcCall(rpc, {
              userId: authorization.userId!,
              sessionId: authorization.accountSessionId!,
              connectionId: input.connectionId,
              signal,
              sendRaw: (message) => sendV3Update(message, sendUpdate),
              sendRpcReply: () => {},
              inlineProtocol: authorization.permanentAuthKeyId
                ? { permanentAuthKeyId: authorization.permanentAuthKeyId }
                : undefined,
            })
          })
          return {
            kind: "result",
            terminateAuthorization: rpc.method === Method.LOG_OUT,
            replayPayload: rpc.method === Method.GET_FILE_PART
              ? freshRequestIdRequiredResponse()
              : undefined,
            payload: RealtimeV3Response.toBinary({
              body: {
                oneofKind: "rpcResult",
                rpcResult: { reqMsgId: 0n, result },
              },
            }),
          }
        }
        return { kind: "result", payload: unauthorizedResponse() }
      } catch (error) {
        if (error instanceof InlineProtocolApplicationOutputOverloaded) throw error
        if (signal.aborted) throw signal.reason ?? error
        return { kind: "result", payload: errorResponse(error) }
      }
    },
  }
}
