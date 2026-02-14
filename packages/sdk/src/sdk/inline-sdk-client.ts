import {
  GetChatInput,
  GetMessagesInput,
  GetMeInput,
  GetUpdatesInput,
  GetUpdatesResult_ResultType,
  GetUpdatesStateInput,
  InputPeer,
  MessageSendMode,
  Method,
  type Message,
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
  InlineSdkGetMessagesParams,
  InlineSdkSendMessageMedia,
  InlineSdkSendMessageParams,
  InlineSdkState,
  InlineSdkUploadFileParams,
  InlineSdkUploadFileResult,
  MappedMethod,
  RpcInputForMethod,
  RpcResultForMethod,
} from "./types.js"
import { rpcInputKindByMethod, rpcResultKindByMethod } from "./types.js"
import { noopLogger, type InlineSdkLogger } from "./logger.js"
import { getSdkVersion } from "./sdk-version.js"

const nowSeconds = () => BigInt(Math.floor(Date.now() / 1000))
const sdkLayer = 1
const defaultApiBaseUrl = "https://api.inline.chat"
const defaultVideoWidth = 1280
const defaultVideoHeight = 720
const defaultVideoDuration = 1

function extractFirstMessageId(updates: Update[] | undefined): bigint | null {
  for (const update of updates ?? []) {
    if (update.update.oneofKind === "newMessage") {
      const message = update.update.newMessage.message
      if (message) return message.id
    }
  }
  return null
}

export class InlineSdkClient {
  private readonly options: InlineSdkClientOptions
  private readonly log: InlineSdkLogger
  private readonly httpBaseUrl: string
  private readonly fetchImpl: typeof fetch

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

    this.httpBaseUrl = normalizeHttpBaseUrl(options.baseUrl ?? defaultApiBaseUrl)
    this.fetchImpl = options.fetch ?? fetch

    const url = resolveRealtimeUrl(this.httpBaseUrl)
    this.transport = options.transport ?? new WebSocketTransport({ url, logger: options.logger })
    this.protocol = new ProtocolClient({
      transport: this.transport,
      getConnectionInit: () => ({
        token: options.token,
        layer: sdkLayer,
        clientVersion: getSdkVersion(),
      }),
      logger: options.logger,
      defaultRpcTimeoutMs: options.rpcTimeoutMs,
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

  async getMessages(params: InlineSdkGetMessagesParams): Promise<{ messages: Message[] }> {
    const peerId = this.inputPeerFromTarget(params, "getMessages")
    const messageIds = params.messageIds.map((messageId, index) => asInlineId(messageId, `messageIds[${index}]`))

    const result = await this.invoke(Method.GET_MESSAGES, {
      oneofKind: "getMessages",
      getMessages: GetMessagesInput.create({
        peerId,
        messageIds,
      }),
    })

    return { messages: result.getMessages.messages }
  }

  async sendMessage(params: InlineSdkSendMessageParams): Promise<{ messageId: bigint | null }> {
    if (params.entities != null && params.parseMarkdown != null) {
      throw new Error("sendMessage: provide either `entities` or `parseMarkdown`, not both")
    }

    const hasText = typeof params.text === "string" && params.text.length > 0
    if (!hasText && params.media == null) {
      throw new Error("sendMessage: provide `text` and/or `media`")
    }
    if (params.parseMarkdown != null && !hasText) {
      throw new Error("sendMessage: `parseMarkdown` requires non-empty `text`")
    }
    if (params.entities != null && !hasText) {
      throw new Error("sendMessage: `entities` requires non-empty `text`")
    }

    const peerId = this.inputPeerFromTarget(params, "sendMessage")
    const media = params.media != null ? toInputMedia(params.media) : undefined

    let result: RpcResultForMethod<Method.SEND_MESSAGE>
    try {
      result = await this.invoke(Method.SEND_MESSAGE, {
        oneofKind: "sendMessage",
        sendMessage: {
          peerId,
          ...(hasText ? { message: params.text } : {}),
          ...(media != null ? { media } : {}),
          ...(params.replyToMsgId != null ? { replyToMsgId: asInlineId(params.replyToMsgId, "replyToMsgId") } : {}),
          ...(params.parseMarkdown != null ? { parseMarkdown: params.parseMarkdown } : {}),
          ...(params.entities != null ? { entities: params.entities } : {}),
          ...(params.sendMode === "silent" ? { sendMode: MessageSendMode.MODE_SILENT } : {}),
        },
      })
    } catch (error) {
      const target = "chatId" in params ? `chat:${String(params.chatId)}` : `user:${String(params.userId)}`
      const mediaKind = params.media?.kind ?? "none"
      const textLen = hasText ? params.text!.length : 0
      const detail = extractErrorMessage(error)
      throw new Error(
        `sendMessage: request failed (${detail}; target=${target}; media=${mediaKind}; textLen=${textLen}; replyTo=${params.replyToMsgId != null ? String(params.replyToMsgId) : "none"})`,
        { cause: error as Error },
      )
    }

    const messageId = extractFirstMessageId(result.sendMessage.updates)
    return { messageId }
  }

  async uploadFile(params: InlineSdkUploadFileParams): Promise<InlineSdkUploadFileResult> {
    const form = new FormData()
    form.set("type", params.type)

    const fileName = normalizeUploadFileName(params.fileName, params.type)
    const fileContentType = resolveUploadContentType(params.type, params.contentType)
    form.set("file", toUploadMultipartFile(params.file, fileName, fileContentType), fileName)
    const fileSize = getBinaryInputSize(params.file)

    let thumbnailName: string | undefined
    let thumbnailContentType: string | undefined
    let thumbnailSize: number | undefined
    if (params.thumbnail != null) {
      thumbnailName = normalizeUploadFileName(
        params.thumbnailFileName,
        "photo",
      )
      thumbnailContentType = resolveUploadContentType(
        "photo",
        params.thumbnailContentType,
      )
      thumbnailSize = getBinaryInputSize(params.thumbnail)
      form.set(
        "thumbnail",
        toUploadMultipartFile(params.thumbnail, thumbnailName, thumbnailContentType),
        thumbnailName,
      )
    }

    if (params.type === "video") {
      const width = normalizePositiveInt(params.width, "width") ?? defaultVideoWidth
      const height = normalizePositiveInt(params.height, "height") ?? defaultVideoHeight
      const duration = normalizePositiveInt(params.duration, "duration") ?? defaultVideoDuration
      form.set("width", String(width))
      form.set("height", String(height))
      form.set("duration", String(duration))
    }

    const uploadUrl = resolveUploadFileUrl(this.httpBaseUrl)
    const requestContext = describeUploadContext({
      type: params.type,
      fileName,
      fileContentType,
      fileSize,
      ...(thumbnailName ? { thumbnailName } : {}),
      ...(thumbnailContentType ? { thumbnailContentType } : {}),
      ...(thumbnailSize != null ? { thumbnailSize } : {}),
      ...(params.type === "video"
        ? {
            width: params.width ?? defaultVideoWidth,
            height: params.height ?? defaultVideoHeight,
            duration: params.duration ?? defaultVideoDuration,
          }
        : {}),
      uploadUrl: uploadUrl.toString(),
    })
    let response: Response
    try {
      response = await this.fetchImpl(uploadUrl, {
        method: "POST",
        headers: {
          authorization: `Bearer ${this.options.token}`,
        },
        body: form,
      })
    } catch (error) {
      const detail = extractErrorMessage(error)
      throw new Error(`uploadFile: network request failed (${detail}; ${requestContext})`, {
        cause: error as Error,
      })
    }

    const payload = await parseJsonResponse(response)
    if (!response.ok) {
      const detail = describeUploadFailure(payload)
      throw new Error(
        `uploadFile: request failed with status ${response.status}${detail ? ` (${detail})` : ""}; ${requestContext}`,
      )
    }
    if (!isRecord(payload) || payload.ok !== true) {
      const detail = describeUploadFailure(payload)
      throw new Error(`uploadFile: API error${detail ? ` (${detail})` : ""}; ${requestContext}`)
    }
    const result = payload.result
    if (!isRecord(result)) {
      throw new Error(`uploadFile: malformed success payload; ${requestContext}`)
    }
    const fileUniqueId = typeof result.fileUniqueId === "string" ? result.fileUniqueId.trim() : ""
    if (!fileUniqueId) {
      throw new Error(`uploadFile: response missing fileUniqueId; ${requestContext}`)
    }
    const photoId = parseOptionalBigInt(result.photoId, "photoId")
    const videoId = parseOptionalBigInt(result.videoId, "videoId")
    const documentId = parseOptionalBigInt(result.documentId, "documentId")

    return {
      fileUniqueId,
      ...(photoId != null ? { photoId } : {}),
      ...(videoId != null ? { videoId } : {}),
      ...(documentId != null ? { documentId } : {}),
    }
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
    options?: { timeoutMs?: number | null },
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
    options?: { timeoutMs?: number | null },
  ): Promise<RpcResult["result"]> {
    return await this.protocol.callRpc(method, input, options)
  }

  async invoke<M extends MappedMethod>(
    method: M,
    input: RpcInputForMethod<M>,
    options?: { timeoutMs?: number | null },
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

function toInputMedia(media: InlineSdkSendMessageMedia): {
  media:
    | { oneofKind: "photo"; photo: { photoId: bigint } }
    | { oneofKind: "video"; video: { videoId: bigint } }
    | { oneofKind: "document"; document: { documentId: bigint } }
} {
  switch (media.kind) {
    case "photo":
      return {
        media: {
          oneofKind: "photo",
          photo: {
            photoId: asInlineId(media.photoId, "photoId"),
          },
        },
      }
    case "video":
      return {
        media: {
          oneofKind: "video",
          video: {
            videoId: asInlineId(media.videoId, "videoId"),
          },
        },
      }
    case "document":
      return {
        media: {
          oneofKind: "document",
          document: {
            documentId: asInlineId(media.documentId, "documentId"),
          },
        },
      }
  }
}

function normalizeHttpBaseUrl(baseUrl: string): string {
  const url = new URL(baseUrl)
  const path = url.pathname.replace(/\/+$/, "")
  url.pathname = path || "/"
  return url.toString().replace(/\/$/, "")
}

function normalizeUploadFileName(raw: string | undefined, type: "photo" | "video" | "document"): string {
  const trimmed = sanitizeUploadFileName(raw)
  if (trimmed) return trimmed
  switch (type) {
    case "photo":
      return "photo.jpg"
    case "video":
      return "video.mp4"
    case "document":
      return "document.bin"
  }
}

function resolveUploadContentType(type: "photo" | "video" | "document", explicit: string | undefined): string {
  const trimmed = explicit?.trim()
  if (trimmed) return trimmed
  switch (type) {
    case "photo":
      return "image/jpeg"
    case "video":
      return "video/mp4"
    case "document":
      return "application/octet-stream"
  }
}

function toBlob(input: InlineSdkUploadFileParams["file"], type: string): Blob {
  if (input instanceof Blob) {
    return input.type === type ? input : new Blob([input], { type })
  }
  return new Blob([input], { type })
}

function toUploadMultipartFile(
  input: InlineSdkUploadFileParams["file"],
  fileName: string,
  type: string,
): Blob | File {
  const blob = toBlob(input, type)
  if (typeof File === "undefined") return blob
  return new File([blob], fileName, { type })
}

function sanitizeUploadFileName(raw: string | undefined): string {
  const trimmed = raw?.trim()
  if (!trimmed) return ""
  const normalized = trimmed.replace(/\\/g, "/")
  const leaf = normalized.split("/").pop() ?? normalized
  const noQuery = leaf.split(/[?#]/, 1)[0] ?? leaf
  return noQuery.trim()
}

function getBinaryInputSize(input: InlineSdkUploadFileParams["file"]): number {
  if (input instanceof Blob) return input.size
  if (input instanceof Uint8Array) return input.byteLength
  return input.byteLength
}

function describeUploadContext(params: {
  type: "photo" | "video" | "document"
  fileName: string
  fileContentType: string
  fileSize: number
  thumbnailName?: string
  thumbnailContentType?: string
  thumbnailSize?: number
  width?: number
  height?: number
  duration?: number
  uploadUrl: string
}): string {
  const parts = [
    `type=${params.type}`,
    `fileName=${params.fileName}`,
    `fileContentType=${params.fileContentType}`,
    `fileSize=${params.fileSize}`,
    `uploadUrl=${params.uploadUrl}`,
  ]
  if (params.thumbnailName) parts.push(`thumbnailName=${params.thumbnailName}`)
  if (params.thumbnailContentType) parts.push(`thumbnailContentType=${params.thumbnailContentType}`)
  if (params.thumbnailSize != null) parts.push(`thumbnailSize=${params.thumbnailSize}`)
  if (params.width != null) parts.push(`width=${params.width}`)
  if (params.height != null) parts.push(`height=${params.height}`)
  if (params.duration != null) parts.push(`duration=${params.duration}`)
  return parts.join(", ")
}

function extractErrorMessage(error: unknown): string {
  if (error instanceof Error) return error.message
  return String(error)
}

function normalizePositiveInt(value: number | undefined, field: string): number | undefined {
  if (value == null) return undefined
  if (!Number.isFinite(value) || !Number.isInteger(value) || value <= 0) {
    throw new Error(`uploadFile: ${field} must be a positive integer`)
  }
  return value
}

async function parseJsonResponse(response: Response): Promise<unknown> {
  const contentType = response.headers.get("content-type") ?? ""
  if (!contentType.includes("application/json")) {
    const text = await response.text()
    return text
  }
  try {
    return await response.json()
  } catch {
    return null
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}

function describeUploadFailure(payload: unknown): string {
  if (typeof payload === "string") {
    const trimmed = payload.trim()
    return trimmed ? trimmed : ""
  }
  if (!isRecord(payload)) return ""
  const description = typeof payload.description === "string" ? payload.description.trim() : ""
  if (description) return description
  const error = typeof payload.error === "string" ? payload.error.trim() : ""
  if (error) return error
  return ""
}

function parseOptionalBigInt(value: unknown, field: string): bigint | undefined {
  if (value == null) return undefined
  if (typeof value === "bigint") return value
  if (typeof value === "number") {
    if (!Number.isFinite(value) || !Number.isInteger(value) || !Number.isSafeInteger(value)) {
      throw new Error(`uploadFile: invalid ${field} in response`)
    }
    return BigInt(value)
  }
  if (typeof value === "string") {
    const trimmed = value.trim()
    if (!trimmed) return undefined
    try {
      return BigInt(trimmed)
    } catch {
      throw new Error(`uploadFile: invalid ${field} in response`)
    }
  }
  throw new Error(`uploadFile: invalid ${field} in response`)
}

const resolveRealtimeUrl = (baseUrl: string): string => {
  const url = new URL(baseUrl)
  const isSecure = url.protocol === "https:"
  url.protocol = isSecure ? "wss:" : "ws:"
  url.pathname = url.pathname.replace(/\/+$/, "") + "/realtime"
  return url.toString()
}

const resolveUploadFileUrl = (baseUrl: string): URL => {
  const url = new URL(baseUrl)
  const basePath = url.pathname.replace(/\/+$/, "")
  url.pathname = `${basePath}/v1/uploadFile`
  return url
}

const hasMethodMapping = (method: Method): method is MappedMethod =>
  Object.prototype.hasOwnProperty.call(rpcInputKindByMethod, method) &&
  Object.prototype.hasOwnProperty.call(rpcResultKindByMethod, method)
