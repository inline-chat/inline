import {
  GetChatInput,
  GetMeInput,
  GetUpdatesInput,
  GetUpdatesResult_ResultType,
  GetUpdatesStateInput,
  InputPeer,
  MessageEntities,
  MessageSendMode,
  Method,
  type Peer,
  type RpcCall,
  type RpcResult,
  type Update,
  UpdateBucket,
  UpdateComposeAction_ComposeAction,
} from "@inline-chat/protocol/core"
import { asInlineId, type InlineIdLike } from "../ids.js"
import { AsyncChannel } from "../utils/async-channel.js"
import { ProtocolClient } from "../realtime/protocol-client.js"
import { WebSocketTransport } from "../realtime/ws-transport.js"
import type { Transport } from "../realtime/transport.js"
import type {
  InlineSdkClientOptions,
  InlineInboundEvent,
  InlineSdkState,
  MappedMethod,
  RpcInputForMethod,
  RpcResultForMethod,
} from "./types.js"
import { rpcInputKindByMethod, rpcResultKindByMethod } from "./types.js"
import { noopLogger, type InlineSdkLogger } from "./logger.js"
import { getSdkVersion } from "./sdk-version.js"

const nowSeconds = () => BigInt(Math.floor(Date.now() / 1000))
const sdkLayer = 1

function extractFirstMessageId(updates: Update[] | undefined): bigint | null {
  for (const update of updates ?? []) {
    if (update.update.oneofKind === "newMessage") {
      const message = update.update.newMessage.message
      if (message) return message.id
    }
  }
  return null
}

type SendMessageTarget =
  | { chatId: InlineIdLike; userId?: never }
  | { userId: InlineIdLike; chatId?: never }

export class InlineSdkClient {
  private readonly options: InlineSdkClientOptions
  private readonly log: InlineSdkLogger

  private readonly transport: Transport
  private readonly protocol: ProtocolClient
  private readonly eventStream = new AsyncChannel<InlineInboundEvent>()

  private started = false
  private openPromise: Promise<void> | null = null
  private openResolver: (() => void) | null = null
  private openRejecter: ((error: Error) => void) | null = null

  private state: InlineSdkState = { version: 1 }
  private saveTimer: ReturnType<typeof setTimeout> | null = null
  private saveInFlight: Promise<void> | null = null

  private catchUpInFlightByChatId = new Map<bigint, Promise<void>>()

  constructor(options: InlineSdkClientOptions) {
    this.options = options
    this.log = options.logger ?? noopLogger

    const baseUrl = options.baseUrl ?? "https://api.inline.chat"
    const url = resolveRealtimeUrl(baseUrl)
    this.transport = options.transport ?? new WebSocketTransport({ url, logger: options.logger })
    this.protocol = new ProtocolClient({
      transport: this.transport,
      getConnectionInit: () => ({
        token: options.token,
        layer: sdkLayer,
        clientVersion: getSdkVersion(),
      }),
      logger: options.logger,
    })

    void this.startListeners()
  }

  async connect(signal?: AbortSignal): Promise<void> {
    if (this.started) {
      // If a connection attempt is already in-flight, callers should still
      // await readiness.
      if (this.openPromise) await this.openPromise
      return
    }
    this.started = true

    if (signal?.aborted) throw new Error("aborted")

    const openPromise = new Promise<void>((resolve, reject) => {
      this.openResolver = resolve
      this.openRejecter = reject
    })
    this.openPromise = openPromise
    // If connect() fails before we ever `await openPromise`, we still reject it
    // to unblock concurrent callers. Ensure the rejection is always handled.
    openPromise.catch(() => {})

    if (signal) {
      signal.addEventListener(
        "abort",
        () => {
          // Ensure connect() doesn't hang if we're aborted before `open`.
          this.rejectOpen(new Error("aborted"))
          void this.close()
        },
        { once: true },
      )
    }

    try {
      await this.loadState()
      await this.protocol.startTransport()

      // Wait until authenticated and connection is open.
      await openPromise
    } catch (error) {
      // If connect() fails, leave the client in a "stopped" state so callers can retry.
      this.started = false
      const err = error instanceof Error ? error : new Error(String(error))
      this.rejectOpen(err)
      await this.protocol.stopTransport().catch(() => {})
      throw err
    } finally {
      if (this.openPromise === openPromise) {
        this.openPromise = null
      }
    }
  }

  async close(): Promise<void> {
    if (!this.started) return
    this.started = false

    this.rejectOpen(new Error("closed"))

    this.eventStream.close()
    await Promise.allSettled(this.catchUpInFlightByChatId.values())
    await this.flushStateSave()
    await this.protocol.stopTransport()
  }

  private rejectOpen(error: Error) {
    this.openRejecter?.(error)
    this.openResolver = null
    this.openRejecter = null
  }

  events(): AsyncIterable<InlineInboundEvent> {
    return this.eventStream
  }

  exportState(): InlineSdkState {
    return {
      version: 1,
      ...(this.state.dateCursor != null ? { dateCursor: this.state.dateCursor } : {}),
      ...(this.state.lastSeqByChatId != null ? { lastSeqByChatId: { ...this.state.lastSeqByChatId } } : {}),
    }
  }

  async getMe(): Promise<{ userId: bigint }> {
    const result = await this.invoke(Method.GET_ME, { oneofKind: "getMe", getMe: GetMeInput.create({}) })
    if (!result.getMe.user) throw new Error("getMe: missing user")
    return { userId: result.getMe.user.id }
  }

  async getChat(params: { chatId: InlineIdLike }): Promise<{ chatId: bigint; peer?: Peer; title: string }> {
    const peerId = InputPeer.create({
      type: { oneofKind: "chat", chat: { chatId: asInlineId(params.chatId, "chatId") } },
    })

    const result = await this.invoke(Method.GET_CHAT, {
      oneofKind: "getChat",
      getChat: GetChatInput.create({ peerId }),
    })

    const chat = result.getChat.chat
    if (!chat) throw new Error("getChat: missing chat")
    return { chatId: chat.id, peer: chat.peerId, title: chat.title }
  }

  async sendMessage(
    params: SendMessageTarget & {
      text: string
      replyToMsgId?: InlineIdLike
      parseMarkdown?: boolean
      sendMode?: "silent"
      // Optional explicit entities. Mutually exclusive with parseMarkdown for now.
      entities?: MessageEntities
    },
  ): Promise<{ messageId: bigint | null }> {
    if (params.entities != null && params.parseMarkdown != null) {
      throw new Error("sendMessage: provide either `entities` or `parseMarkdown`, not both")
    }

    const peerId = this.inputPeerFromTarget(params, "sendMessage")

    const result = await this.invoke(Method.SEND_MESSAGE, {
      oneofKind: "sendMessage",
      sendMessage: {
        peerId,
        message: params.text,
        ...(params.replyToMsgId != null ? { replyToMsgId: asInlineId(params.replyToMsgId, "replyToMsgId") } : {}),
        ...(params.parseMarkdown != null ? { parseMarkdown: params.parseMarkdown } : {}),
        ...(params.entities != null ? { entities: params.entities } : {}),
        ...(params.sendMode === "silent" ? { sendMode: MessageSendMode.MODE_SILENT } : {}),
      },
    })

    const messageId = extractFirstMessageId(result.sendMessage.updates)
    return { messageId }
  }

  async sendTyping(params: { chatId: InlineIdLike; typing: boolean }): Promise<void> {
    const peerId = InputPeer.create({
      type: { oneofKind: "chat", chat: { chatId: asInlineId(params.chatId, "chatId") } },
    })

    await this.invoke(Method.SEND_COMPOSE_ACTION, {
      oneofKind: "sendComposeAction",
      sendComposeAction: {
        peerId,
        ...(params.typing ? { action: UpdateComposeAction_ComposeAction.TYPING } : {}),
      },
    })
  }

  // Raw RPC invocation escape hatch. Validates method/input/result when the SDK
  // has a mapping for the method; otherwise behaves like unchecked raw.
  async invokeRaw(
    method: Method,
    input: RpcCall["input"] = { oneofKind: undefined },
    options?: { timeoutMs?: number },
  ): Promise<RpcResult["result"]> {
    if (hasMethodMapping(method)) {
      this.assertMethodInputMatch(method, input)
    }
    const result = await this.protocol.callRpc(method, input, options)
    if (hasMethodMapping(method)) {
      this.assertMethodResultMatch(method, result)
    }
    return result
  }

  // Unchecked raw RPC invocation for forward-compat when new methods/types land
  // before the SDK updates its method<->oneof mappings.
  async invokeUncheckedRaw(
    method: Method,
    input: RpcCall["input"] = { oneofKind: undefined },
    options?: { timeoutMs?: number },
  ): Promise<RpcResult["result"]> {
    return await this.protocol.callRpc(method, input, options)
  }

  async invoke<M extends MappedMethod>(
    method: M,
    input: RpcInputForMethod<M>,
    options?: { timeoutMs?: number },
  ): Promise<RpcResultForMethod<M>> {
    this.assertMethodInputMatch(method, input)
    const result = await this.protocol.callRpc(method, input, options)
    this.assertMethodResultMatch(method, result)
    return result
  }

  private assertMethodInputMatch(method: MappedMethod, input: RpcCall["input"]) {
    const expected = rpcInputKindByMethod[method]
    if (expected == null) {
      if (input.oneofKind !== undefined) {
        throw new Error(`rpc input mismatch: method ${Method[method]} expects no input`)
      }
      return
    }
    if (input.oneofKind !== expected) {
      throw new Error(`rpc input mismatch: method ${Method[method]} expects ${expected}`)
    }
  }

  private assertMethodResultMatch<M extends MappedMethod>(
    method: M,
    result: RpcResult["result"],
  ): asserts result is RpcResultForMethod<M> {
    const expected = rpcResultKindByMethod[method]
    if (expected == null) {
      if (result.oneofKind !== undefined) {
        throw new Error(`rpc result mismatch: method ${Method[method]} expects no result`)
      }
      return
    }
    if (result.oneofKind !== expected) {
      throw new Error(`rpc result mismatch: method ${Method[method]} expects ${expected}`)
    }
  }

  private async startListeners() {
    ;(async () => {
      for await (const event of this.protocol.events) {
        switch (event.type) {
          case "open":
            await this.onOpen()
            break
          case "updates":
            await this.onUpdates(event.updates.updates)
            break
          case "rpcError":
          case "rpcResult":
          case "ack":
          case "connecting":
            break
        }
      }
    })().catch((error) => {
      this.log.error?.("SDK listener crashed", error)
      this.rejectOpen(error instanceof Error ? error : new Error("listener-crashed"))
    })
  }

  private async onOpen() {
    this.openResolver?.()
    this.openResolver = null
    this.openRejecter = null

    // Best-effort: do not block `connect()` on cursor initialization.
    void this.initializeDateCursor()
  }

  private async initializeDateCursor() {
    const date = this.state.dateCursor ?? nowSeconds()
    try {
      const result = await this.invoke(Method.GET_UPDATES_STATE, {
        oneofKind: "getUpdatesState",
        getUpdatesState: GetUpdatesStateInput.create({ date }),
      }, { timeoutMs: 1500 })
      this.state.dateCursor = result.getUpdatesState.date
      this.scheduleStateSave()
    } catch (error) {
      // Not all deployments may support this yet; treat as best-effort.
      this.log.warn?.("GET_UPDATES_STATE failed (continuing without date cursor)", error)
    }
  }

  private async onUpdates(updates: Update[]) {
    for (const update of updates) {
      await this.handleUpdate(update)
    }
  }

  private async handleUpdate(update: Update) {
    const seq = update.seq ?? 0
    const date = update.date ?? 0n

    switch (update.update.oneofKind) {
      case "newMessage": {
        const message = update.update.newMessage.message
        if (!message) return
        this.bumpChatSeq(message.chatId, seq)
        await this.eventStream.send({
          kind: "message.new",
          chatId: message.chatId,
          message,
          seq,
          date,
        })
        return
      }

      case "editMessage": {
        const message = update.update.editMessage.message
        if (!message) return
        this.bumpChatSeq(message.chatId, seq)
        await this.eventStream.send({
          kind: "message.edit",
          chatId: message.chatId,
          message,
          seq,
          date,
        })
        return
      }

      case "deleteMessages": {
        const payload = update.update.deleteMessages
        const chatId = payload.peerId?.type.oneofKind === "chat" ? payload.peerId.type.chat.chatId : null
        if (!chatId) {
          this.log.warn?.("Skipping deleteMessages update without chat peer", payload.peerId)
          return
        }
        this.bumpChatSeq(chatId, seq)
        await this.eventStream.send({
          kind: "message.delete",
          chatId,
          messageIds: payload.messageIds,
          seq,
          date,
        })
        return
      }

      case "updateReaction": {
        const reaction = update.update.updateReaction.reaction
        if (!reaction) return
        this.bumpChatSeq(reaction.chatId, seq)
        await this.eventStream.send({
          kind: "reaction.add",
          chatId: reaction.chatId,
          reaction,
          seq,
          date,
        })
        return
      }

      case "deleteReaction": {
        const payload = update.update.deleteReaction
        this.bumpChatSeq(payload.chatId, seq)
        await this.eventStream.send({
          kind: "reaction.delete",
          chatId: payload.chatId,
          emoji: payload.emoji,
          messageId: payload.messageId,
          userId: payload.userId,
          seq,
          date,
        })
        return
      }

      case "chatHasNewUpdates": {
        const payload = update.update.chatHasNewUpdates
        await this.eventStream.send({
          kind: "chat.hasUpdates",
          chatId: payload.chatId,
          seq,
          date,
        })
        await this.catchUpChat({ chatId: payload.chatId, peer: payload.peerId, updateSeq: payload.updateSeq, update })
        return
      }

      case "spaceHasNewUpdates": {
        const payload = update.update.spaceHasNewUpdates
        await this.eventStream.send({
          kind: "space.hasUpdates",
          spaceId: payload.spaceId,
          seq,
          date,
        })
        // Space catch-up is intentionally a no-op for MVP.
        return
      }

      default:
        return
    }
  }

  private bumpChatSeq(chatId: bigint, seq: number) {
    if (!Number.isFinite(seq)) return
    if (!this.state.lastSeqByChatId) this.state.lastSeqByChatId = {}
    const key = chatId.toString()
    const prev = this.state.lastSeqByChatId[key] ?? 0
    if (seq > prev) {
      this.state.lastSeqByChatId[key] = seq
      this.scheduleStateSave()
    }
  }

  private async catchUpChat(params: { chatId: bigint; peer?: Peer; updateSeq: number; update: Update }) {
    const key = params.chatId.toString()
    const lastSeq = this.state.lastSeqByChatId?.[key]
    const startSeq = lastSeq ?? params.updateSeq // default skip backlog
    if (params.updateSeq <= startSeq) return

    if (this.catchUpInFlightByChatId.has(params.chatId)) {
      await this.catchUpInFlightByChatId.get(params.chatId)
      return
    }

    const task = this.doCatchUpChat(params.chatId, params.peer, startSeq, params.updateSeq).finally(() => {
      this.catchUpInFlightByChatId.delete(params.chatId)
    })
    this.catchUpInFlightByChatId.set(params.chatId, task)
    await task
  }

  private async doCatchUpChat(chatId: bigint, peer: Peer | undefined, startSeq: number, endSeq: number) {
    let cursor = startSeq

    while (cursor < endSeq) {
      const result = await this.invoke(Method.GET_UPDATES, {
        oneofKind: "getUpdates",
        getUpdates: GetUpdatesInput.create({
          bucket: UpdateBucket.create({
            type: {
              oneofKind: "chat",
              chat: {
                peerId: this.peerToInputPeer(peer, chatId),
              },
            },
          }),
          startSeq: BigInt(cursor),
          seqEnd: BigInt(endSeq),
          totalLimit: 1000,
        }),
      })

      const payload = result.getUpdates

      if (payload.resultType === GetUpdatesResult_ResultType.TOO_LONG) {
        this.log.warn?.("GET_UPDATES too long; fast-forwarding cursor", { chatId: chatId.toString(), seq: payload.seq })
        this.bumpChatSeq(chatId, endSeq)
        if (payload.date !== 0n) {
          this.state.dateCursor = payload.date
        }
        this.scheduleStateSave()
        return
      }

      const deliveredSeq = Number(payload.seq ?? 0n)
      if (!Number.isSafeInteger(deliveredSeq)) {
        this.log.warn?.("GET_UPDATES returned non-integer seq; aborting catch-up", { chatId: chatId.toString() })
        return
      }

      // Mark the cursor as caught up to this slice before emitting any events.
      this.bumpChatSeq(chatId, deliveredSeq)

      for (const update of payload.updates) {
        await this.handleUpdate(update)
      }

      if (payload.date !== 0n) {
        this.state.dateCursor = payload.date
      }
      this.scheduleStateSave()

      if (payload.final) return
      if (deliveredSeq <= cursor) {
        this.log.warn?.("GET_UPDATES made no progress; aborting catch-up", { chatId: chatId.toString(), cursor, deliveredSeq })
        return
      }
      cursor = deliveredSeq
    }
  }

  private peerToInputPeer(peer: Peer | undefined, chatId: bigint): InputPeer {
    if (!peer) {
      return InputPeer.create({ type: { oneofKind: "chat", chat: { chatId } } })
    }

    switch (peer.type.oneofKind) {
      case "chat":
        return InputPeer.create({ type: { oneofKind: "chat", chat: { chatId: peer.type.chat.chatId } } })
      case "user":
        return InputPeer.create({ type: { oneofKind: "user", user: { userId: peer.type.user.userId } } })
      default:
        return InputPeer.create({ type: { oneofKind: "chat", chat: { chatId } } })
    }
  }

  private inputPeerFromTarget(params: { chatId?: InlineIdLike; userId?: InlineIdLike }, methodName: string): InputPeer {
    const hasChatId = params.chatId != null
    const hasUserId = params.userId != null
    if (hasChatId === hasUserId) {
      throw new Error(`${methodName}: provide exactly one of \`chatId\` or \`userId\``)
    }

    if (hasUserId) {
      return InputPeer.create({
        type: { oneofKind: "user", user: { userId: asInlineId(params.userId as InlineIdLike, "userId") } },
      })
    }

    return InputPeer.create({
      type: { oneofKind: "chat", chat: { chatId: asInlineId(params.chatId as InlineIdLike, "chatId") } },
    })
  }

  private async loadState() {
    const store = this.options.state
    if (!store) return
    const loaded = await store.load()
    if (!loaded) return
    if (loaded.version !== 1) return
    this.state = loaded
  }

  private scheduleStateSave() {
    const store = this.options.state
    if (!store) return
    if (!this.started) return
    if (this.saveTimer) return
    this.saveTimer = setTimeout(() => {
      this.saveTimer = null
      void this.flushStateSave()
    }, 250)
  }

  private async flushStateSave() {
    const store = this.options.state
    if (!store) return

    if (this.saveTimer) {
      clearTimeout(this.saveTimer)
      this.saveTimer = null
    }

    if (this.saveInFlight) {
      await this.saveInFlight
      return
    }

    const snapshot: InlineSdkState = {
      version: 1,
      ...(this.state.dateCursor != null ? { dateCursor: this.state.dateCursor } : {}),
      ...(this.state.lastSeqByChatId != null ? { lastSeqByChatId: { ...this.state.lastSeqByChatId } } : {}),
    }

    this.saveInFlight = store
      .save(snapshot)
      .catch((error) => {
        this.log.warn?.("Failed to persist SDK state", error)
      })
      .finally(() => {
        this.saveInFlight = null
      })

    await this.saveInFlight
  }
}

const resolveRealtimeUrl = (baseUrl: string): string => {
  const url = new URL(baseUrl)
  const isSecure = url.protocol === "https:"
  url.protocol = isSecure ? "wss:" : "ws:"
  url.pathname = url.pathname.replace(/\/+$/, "") + "/realtime"
  return url.toString()
}

const hasMethodMapping = (method: Method): method is MappedMethod =>
  Object.prototype.hasOwnProperty.call(rpcInputKindByMethod, method) &&
  Object.prototype.hasOwnProperty.call(rpcResultKindByMethod, method)
