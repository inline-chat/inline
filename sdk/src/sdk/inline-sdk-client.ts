import {
  type BotCapability,
  type BotChatSettingsResponse,
  type BotEvent,
  type ClearChatHistoryInput,
  BotPresenceState_Kind,
  GetChatInput,
  GetMessagesInput,
  GetMeInput,
  GetSpaceInput,
  type GetSpaceResult,
  GetUpdatesInput,
  type GetUpdatesResult,
  GetUpdatesResult_ResultType,
  GetUpdatesStateInput,
  InputPeer,
  MessageSendMode,
  Method,
  type Message,
  type Peer,
  type RpcCall,
  type RpcResult,
  SyncSkippedSequence_Reason,
  type Update,
  UpdateBucket,
  UpdateComposeAction_ComposeAction,
  UploadKind,
} from "@inline-chat/protocol/core"
import {
  NativeUploadClient,
  rpcUploadTransport,
  uploadByteSource,
  type UploadByteSource,
} from "@inline-chat/protocol/uploads"
import { asInlineId, type InlineIdLike } from "../ids.js"
import { AcknowledgedAsyncChannel } from "../utils/async-channel.js"
import {
  ProtocolClient,
  ProtocolClientError,
  type RpcCallOptions,
  type RpcReconnectPolicy,
} from "../realtime/protocol-client.js"
import { WebSocketTransport } from "../realtime/ws-transport.js"
import { InlineProtocolV3Transport } from "../realtime/v3-transport.js"
import { INLINE_PROTOCOL_PRODUCTION_PUBLIC_KEYS } from "../realtime/production-trust-roots.js"
import type { Transport } from "../realtime/transport.js"
import type {
  InlineSdkAnswerBotChatSettingsParams,
  InlineSdkAnswerMessageActionParams,
  InlineSdkAuthoritativeRepairRequest,
  InlineSdkClearChatHistoryParams,
  InlineSdkClientOptions,
  InlineSdkChatInfo,
  InlineInboundEvent,
  InlineSdkGetMessagesParams,
  InlineSdkInvokeBotChatSettingsItemParams,
  InlineSdkInvokeMessageActionParams,
  InlineSdkLogoutResult,
  InlineSdkRequestBotChatSettingsParams,
  InlineSdkSendMessageMedia,
  InlineSdkSendMessageParams,
  InlineSdkSetBotPresenceStateParams,
  InlineSdkSetMyBotCapabilitiesParams,
  InlineSdkState,
  InlineSdkSyncStatus,
  InlineSdkUpdateBucketRef,
  InlineSdkUploadFileParams,
  InlineSdkUploadFileResult,
  MappedMethod,
  RpcInputForMethod,
  RpcResultForMethod,
} from "./types.js"
import { rpcInputKindByMethod, rpcResultKindByMethod } from "./types.js"
import { noopLogger, type InlineSdkLogger } from "./logger.js"
import { getSdkVersion } from "./sdk-version.js"
import type { InlineSdkAuthenticationError } from "./errors.js"

const nowSeconds = () => BigInt(Math.floor(Date.now() / 1000))
const sdkLayer = 1
const defaultApiBaseUrl = "https://api.inline.chat"
const defaultVideoWidth = 1280
const defaultVideoHeight = 720
const defaultVideoDuration = 1
const defaultCatchUpPageLimit = 100
const defaultCatchUpTotalLimit = 10_000
const maxDatabaseUpdateSequence = 2_147_483_647
const inboundEventCapacity = 256
const inboundEventCapacityBytes = 8 * 1024 * 1024
const closeJoinTimeoutMs = 2_000
type UpdateSource = "live" | "chat" | "space" | "user"

type DiscoveryTarget = {
  bucket: InlineSdkUpdateBucketRef
  requirement: "through" | "latest"
  seq?: number
  satisfied: boolean
}

type DiscoveryRound = {
  checkpoint?: bigint
  updatesFound?: boolean
  resultReceived: boolean
  collectingHints: boolean
  committing: boolean
  observedHint: boolean
  targets: Map<string, DiscoveryTarget>
}

const eventTextEncoder = new TextEncoder()
const inboundEventByteLength = (value: unknown, ancestors = new Set<object>()): number => {
  if (value == null) return 0
  switch (typeof value) {
    case "string": return eventTextEncoder.encode(value).byteLength
    case "number":
    case "bigint": return 8
    case "boolean": return 1
    case "undefined": return 0
  }
  if (value instanceof Uint8Array) return value.byteLength
  if (typeof value !== "object") return 0
  if (ancestors.has(value)) throw new Error("Inline inbound event must not contain cycles")
  ancestors.add(value)
  try {
    if (Array.isArray(value)) {
      return value.reduce((total, item) => total + inboundEventByteLength(item, ancestors), 0)
    }
    return Object.entries(value).reduce(
      (total, [key, item]) => total + eventTextEncoder.encode(key).byteLength +
        inboundEventByteLength(item, ancestors),
      0,
    )
  } finally {
    ancestors.delete(value)
  }
}

const replaySafeRpcMethods = new Set<Method>([
  Method.GET_ME,
  Method.GET_PEER_PHOTO,
  Method.GET_CHAT_HISTORY,
  Method.GET_SPACE_MEMBERS,
  Method.GET_CHAT_PARTICIPANTS,
  Method.GET_CHATS,
  Method.GET_USER_SETTINGS,
  Method.GET_UPDATES_STATE,
  Method.GET_CHAT,
  Method.GET_UPDATES,
  Method.SEARCH_MESSAGES,
  Method.LIST_BOTS,
  Method.REVEAL_BOT_TOKEN,
  Method.GET_MESSAGES,
  Method.GET_BOT_COMMANDS,
  Method.GET_PEER_BOT_COMMANDS,
  Method.GET_BOT_PRESENCE,
  Method.GET_SESSIONS,
  Method.CHECK_USERNAME,
  Method.GET_SPACE_URL_PREVIEW_EXCLUSIONS,
  Method.GET_USER_GROUPS,
  Method.GET_SPACE_SETTINGS,
  Method.GET_SPACE,
  Method.GET_THREAD_REFERENCES,
  Method.GET_THREAD_SUBTHREADS,
  Method.GET_PEER_BOTS,
  Method.GET_MY_BOT_CAPABILITIES,
  Method.GET_GRID,
  Method.GET_GRID_HOME,
  Method.GET_EXTERNAL_PROFILE_PHOTO,
  Method.GET_CHAT_TRANSCRIPT,
  Method.SEARCH_EXTERNAL_RESOURCES,
  Method.LIST_CONNECTORS,
  Method.SEARCH_USERS,
  Method.RESOLVE_URL_PREVIEW,
  Method.GET_BOT_AGENT,
  Method.LIST_BOT_AGENTS,
  Method.GET_CONNECTOR_CONFIG,
  Method.CREATE_UPLOAD,
  Method.SAVE_UPLOAD_PART,
  Method.GET_UPLOAD_STATE,
  // The server atomically replaces the full set; the SDK also owns reconnect reconciliation.
  Method.SET_MY_BOT_CAPABILITIES,
])

const reconnectPolicyForRpc = (
  method: Method,
  input: RpcCall["input"],
): RpcReconnectPolicy => {
  if (method === Method.SEND_MESSAGE && input.oneofKind === "sendMessage" &&
      input.sendMessage.randomId !== undefined && input.sendMessage.randomId !== 0n) {
    return "replay-safe"
  }
  return replaySafeRpcMethods.has(method) ? "replay-safe" : "never-replay"
}

const randomMessageId = (): bigint => {
  const bytes = new Uint8Array(8)
  globalThis.crypto.getRandomValues(bytes)
  const value = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength).getBigInt64(0, true)
  return value === 0n ? 1n : value
}

const normalizeMessageRandomId = (value: bigint | undefined): bigint => {
  const resolved = value ?? randomMessageId()
  if (resolved === 0n || BigInt.asIntN(64, resolved) !== resolved) {
    throw new RangeError("sendMessage: randomId must be a non-zero signed 64-bit bigint")
  }
  return resolved
}

function extractFirstMessageId(updates: Update[] | undefined): bigint | null {
  for (const update of updates ?? []) {
    if (update.update.oneofKind === "newMessage") {
      const message = update.update.newMessage.message
      if (message) return message.id
    }
    if (update.update.oneofKind === "updateMessageId") {
      return update.update.updateMessageId.messageId
    }
  }
  return null
}

function botPresenceStateKind(kind: InlineSdkSetBotPresenceStateParams["kind"]): BotPresenceState_Kind {
  switch (kind) {
    case "idle":
      return BotPresenceState_Kind.IDLE
    case "happy":
      return BotPresenceState_Kind.HAPPY
    case "waving":
      return BotPresenceState_Kind.WAVING
    case "jumping":
      return BotPresenceState_Kind.JUMPING
    case "failed":
      return BotPresenceState_Kind.FAILED
    case "waiting":
      return BotPresenceState_Kind.WAITING
    case "running":
      return BotPresenceState_Kind.RUNNING
    case "review":
      return BotPresenceState_Kind.REVIEW
  }
}

export class InlineSdkClient {
  private readonly options: InlineSdkClientOptions
  private readonly log: InlineSdkLogger
  private readonly httpBaseUrl: string
  private readonly fetchImpl: typeof fetch

  private readonly transport: Transport
  private readonly protocol: ProtocolClient
  private readonly uploads: NativeUploadClient
  private readonly eventStream = new AcknowledgedAsyncChannel<InlineInboundEvent>(inboundEventCapacity, {
    capacityBytes: inboundEventCapacityBytes,
    byteLength: inboundEventByteLength,
  })

  private started = false
  private closed = false
  private openPromise: Promise<void> | null = null
  private openResolver: (() => void) | null = null
  private openRejecter: ((error: Error) => void) | null = null
  private authenticationError: InlineSdkAuthenticationError | null = null
  private logoutInProgress = false

  private state: InlineSdkState = { version: 1 }
  private saveTimer: ReturnType<typeof setTimeout> | null = null
  private saveInFlight: Promise<boolean> | null = null
  private dirtyStateRevision = 0
  private savedStateRevision = 0

  private catchUpInFlightByChatId = new Map<bigint, Promise<void>>()
  private catchUpRequestedByChatId = new Map<bigint, { endSeq?: number; peer?: Peer; toLatest: boolean }>()
  private catchUpInFlightBySpaceId = new Map<bigint, Promise<void>>()
  private catchUpRequestedBySpaceId = new Map<bigint, { endSeq?: number; toLatest: boolean }>()
  private userCatchUpInFlight: Promise<void> | null = null
  private peerResolutionInFlightByChatId = new Map<bigint, Promise<void>>()
  private peerResolutionRequestedByChatId = new Map<bigint, { endSeq?: number; toLatest: boolean }>()
  private recoveryReconnectInFlight: Promise<void> | null = null
  private degradedUpdateBuckets = new Map<string, InlineSdkUpdateBucketRef>()
  private liveCursorFences = new Set<string>()
  private liveAdmittedSeqByBucket = new Map<string, number>()
  private discoveryRound: DiscoveryRound | null = null
  private discoveryInFlight: Promise<void> | null = null
  private discoveryCommitInFlight: Promise<void> | null = null
  private desiredBotCapabilities: BotCapability[] | null = null
  private desiredBotCapabilitiesRevision = 0
  private registeredBotCapabilitiesRevision = -1
  private botCapabilitiesRegistrationInFlight: Promise<{ capabilities: BotCapability[] }> | null = null

  constructor(options: InlineSdkClientOptions) {
    this.options = options
    this.log = options.logger ?? noopLogger

    this.httpBaseUrl = normalizeHttpBaseUrl(options.baseUrl ?? defaultApiBaseUrl)
    this.fetchImpl = options.fetch ?? fetch

    const v3 = options.inlineProtocol
    if (v3 && options.transport) {
      throw new Error("InlineSdkClient cannot combine a custom transport with Inline Protocol credentials")
    }
    const url = resolveRealtimeUrl(this.httpBaseUrl)
    this.transport = v3
      ? new InlineProtocolV3Transport({
        url: v3.realtimeUrl ?? resolveRealtimeV3Url(this.httpBaseUrl),
        rsaPublicKeys: v3.rsaPublicKeys ?? INLINE_PROTOCOL_PRODUCTION_PUBLIC_KEYS,
        credentials: v3.credentials,
        requestTimeoutMs: options.rpcTimeoutMs ?? undefined,
        logger: options.logger,
        onCredentials: async (credentials) => {
          if (this.logoutInProgress) {
            throw new Error("credential persistence rejected while logout is in progress")
          }
          await v3.onCredentials?.(credentials)
        },
      })
      : options.transport ?? new WebSocketTransport({ url, logger: options.logger })
    const sdkVersion = getSdkVersion()
    this.protocol = new ProtocolClient({
      transport: this.transport,
      getConnectionInit: () => ({
        // The V3 transport consumes this local compatibility message and never transmits its
        // empty token. Authentication is already owned by the bound authorization key.
        token: v3 ? "" : options.token,
        layer: sdkLayer,
        ...(sdkVersion ? { clientVersion: sdkVersion } : {}),
      }),
      processUpdates: (updates) => this.onUpdates(updates.updates),
      logger: options.logger,
      defaultRpcTimeoutMs: options.rpcTimeoutMs,
    })
    this.uploads = new NativeUploadClient(rpcUploadTransport(
      (method, input, signal) => this.invokeUncheckedRaw(method, input, { signal }),
      (error) => error instanceof ProtocolClientError &&
        (error.code === "commit-outcome-unknown" || error.code === "timeout"),
    ))

    void this.startListeners()
  }

  async connect(signal?: AbortSignal): Promise<void> {
    if (this.authenticationError) throw this.authenticationError
    if (this.logoutInProgress) throw new Error("logout in progress")
    if (this.closed) throw new Error("SDK client is closed; create a new InlineSdkClient to reconnect")
    if (signal?.aborted) throw new Error("aborted")
    if (this.started) {
      // If a connection attempt is already in-flight, callers should still
      // await readiness.
      if (this.openPromise) await this.openPromise
      return
    }
    this.started = true

    const openPromise = new Promise<void>((resolve, reject) => {
      this.openResolver = resolve
      this.openRejecter = reject
    })
    this.openPromise = openPromise
    // If connect() fails before we ever `await openPromise`, we still reject it
    // to unblock concurrent callers. Ensure the rejection is always handled.
    openPromise.catch(() => {})

    const abortConnect = () => {
      // Ensure connect() doesn't hang if we're aborted before `open`.
      this.rejectOpen(new Error("aborted"))
      // Aborting a connection attempt remains retryable; it is not an explicit
      // disposal of the client's event stream.
      void this.protocol.stopTransport().catch(() => {})
    }
    signal?.addEventListener("abort", abortConnect, { once: true })

    try {
      await this.loadState()
      if (this.closed || this.logoutInProgress || signal?.aborted) {
        throw new Error(this.closed ? "closed" : this.logoutInProgress ? "logout in progress" : "aborted")
      }
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
      signal?.removeEventListener("abort", abortConnect)
      if (this.openPromise === openPromise) {
        this.openPromise = null
      }
    }
  }

  /**
   * Disconnects without revoking credentials and ends this instance's event
   * stream. After closing a started client, construct a new client to reconnect.
   * Calling close before the first connection attempt is a no-op.
   */
  async close(): Promise<void> {
    if (!this.started) return
    this.closed = true
    this.started = false

    this.rejectOpen(new Error("closed"))

    this.eventStream.close()
    await settleWithin(
      this.protocol.stopTransport(),
      closeJoinTimeoutMs,
      () => this.log.warn?.("Timed out stopping SDK transport during close"),
    )
    await settleWithin(Promise.allSettled([
      ...this.catchUpInFlightByChatId.values(),
      ...this.catchUpInFlightBySpaceId.values(),
      ...(this.userCatchUpInFlight ? [this.userCatchUpInFlight] : []),
      ...this.peerResolutionInFlightByChatId.values(),
    ]), closeJoinTimeoutMs, () => this.log.warn?.("Timed out joining SDK catch-up tasks during close"))
    await this.flushStateSave()
  }

  /**
   * Revokes the remote session best-effort and always destroys host-owned local authority.
   * A durable credential owner is required. Unlike logout, close() preserves
   * host credentials while disposing the started client instance.
   */
  async logout(): Promise<InlineSdkLogoutResult> {
    const owner = this.options.credentialOwner
    if (!owner) throw new Error("logout requires a credentialOwner")
    if (this.logoutInProgress) throw new Error("logout already in progress")

    this.logoutInProgress = true
    try {
      await owner.beginLogout()
      // Even an offline logout disposes this instance's in-memory authority.
      this.closed = true
      let remoteOutcome: InlineSdkLogoutResult["remoteOutcome"] = "notSent"
      if (this.started) {
        try {
          await this.protocol.callRpc(Method.LOG_OUT, {
            oneofKind: "logOut",
            logOut: {},
          }, {
            reconnectPolicy: "never-replay",
            timeoutMs: typeof this.options.rpcTimeoutMs === "number" &&
                Number.isFinite(this.options.rpcTimeoutMs) && this.options.rpcTimeoutMs > 0
              ? Math.min(3_000, this.options.rpcTimeoutMs)
              : 3_000,
          })
          remoteOutcome = "confirmed"
        } catch (error) {
          remoteOutcome = error instanceof ProtocolClientError &&
              ["not-authorized", "not-connected", "stopped", "capacity-exceeded"]
                .includes(error.code)
            ? "notSent"
            : "commitUnknown"
          this.log.warn?.("Remote logout result was not confirmed; continuing local credential destruction", error)
        }
      }
      await this.close()
      this.eventStream.close()
      await owner.clearCredentials()
      await owner.finishLogout()
      return { remoteOutcome }
    } finally {
      this.logoutInProgress = false
    }
  }

  getDiagnostics() {
    return {
      started: this.started,
      baseUrl: this.httpBaseUrl,
      authenticationErrorCode: this.authenticationError?.code ?? null,
      protocol: this.protocol.getDiagnostics(),
      sync: this.getSyncStatus(),
    }
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
      ...(this.state.chatPeerByChatId != null ? { chatPeerByChatId: { ...this.state.chatPeerByChatId } } : {}),
      ...(this.state.lastSeqBySpaceId != null ? { lastSeqBySpaceId: { ...this.state.lastSeqBySpaceId } } : {}),
      ...(this.state.lastUserSeq != null ? { lastUserSeq: this.state.lastUserSeq } : {}),
    }
  }

  getSyncStatus(): InlineSdkSyncStatus {
    return {
      state: this.degradedUpdateBuckets.size > 0
        ? "degraded"
        : this.userCatchUpInFlight ||
            this.catchUpInFlightByChatId.size > 0 ||
            this.catchUpInFlightBySpaceId.size > 0 ||
            this.peerResolutionInFlightByChatId.size > 0
          ? "syncing"
          : "live",
      degradedBuckets: [...this.degradedUpdateBuckets.values()],
    }
  }

  async getMe(): Promise<{ userId: bigint }> {
    const result = await this.invoke(Method.GET_ME, { oneofKind: "getMe", getMe: GetMeInput.create({}) })
    if (!result.getMe.user) throw new Error("getMe: missing user")
    return { userId: result.getMe.user.id }
  }

  async getChat(params: { chatId: InlineIdLike }): Promise<InlineSdkChatInfo> {
    const peerId = InputPeer.create({
      type: { oneofKind: "chat", chat: { chatId: asInlineId(params.chatId, "chatId") } },
    })

    const result = await this.invoke(Method.GET_CHAT, {
      oneofKind: "getChat",
      getChat: GetChatInput.create({ peerId }),
    })

    const chat = result.getChat.chat
    if (!chat) throw new Error("getChat: missing chat")
    if (chat.peerId != null && this.isReliableChatPeer(chat.peerId)) {
      this.rememberChatPeer(chat.id, chat.peerId)
    }
    const dialogFollowMode = result.getChat.dialog?.followMode
    return {
      chatId: chat.id,
      title: chat.title,
      ...(chat.peerId != null ? { peer: chat.peerId } : {}),
      ...(chat.spaceId != null ? { spaceId: chat.spaceId } : {}),
      ...(chat.parentChatId != null ? { parentChatId: chat.parentChatId } : {}),
      ...(chat.parentMessageId != null ? { parentMessageId: chat.parentMessageId } : {}),
      ...(chat.lastMsgId != null ? { lastMsgId: chat.lastMsgId } : {}),
      ...(dialogFollowMode != null ? { dialogFollowMode } : {}),
      ...(chat.isPublic != null ? { isPublic: chat.isPublic } : {}),
      ...(chat.untitled != null ? { untitled: chat.untitled } : {}),
      ...(chat.number != null ? { number: chat.number } : {}),
    }
  }

  async getSpace(params: { spaceId: InlineIdLike }): Promise<GetSpaceResult> {
    const result = await this.invoke(Method.GET_SPACE, {
      oneofKind: "getSpace",
      getSpace: GetSpaceInput.create({ spaceId: asInlineId(params.spaceId, "spaceId") }),
    })
    return result.getSpace
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

  async clearChatHistory(params: InlineSdkClearChatHistoryParams): Promise<void> {
    const keepLastDays = normalizeKeepLastDays(params.keepLastDays)
    const target = this.clearHistoryTargetFromParams(params)

    await this.invoke(Method.CLEAR_CHAT_HISTORY, {
      oneofKind: "clearChatHistory",
      clearChatHistory: {
        target,
        keepLastDays,
        deleteReplyThreads: params.deleteReplyThreads ?? false,
      },
    })
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
    const randomId = normalizeMessageRandomId(params.randomId)

    let result: RpcResultForMethod<Method.SEND_MESSAGE>
    try {
      result = await this.invoke(Method.SEND_MESSAGE, {
        oneofKind: "sendMessage",
        sendMessage: {
          peerId,
          randomId,
          ...(hasText ? { message: params.text } : {}),
          ...(media != null ? { media } : {}),
          ...(params.replyToMsgId != null ? { replyToMsgId: asInlineId(params.replyToMsgId, "replyToMsgId") } : {}),
          ...(params.parseMarkdown != null ? { parseMarkdown: params.parseMarkdown } : {}),
          ...(params.entities != null ? { entities: params.entities } : {}),
          ...(params.actions != null ? { actions: params.actions } : {}),
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
    const fileName = normalizeUploadFileName(params.fileName, params.type)
    const fileContentType = resolveUploadContentType(params.type, params.contentType)
    let thumbnailFileUniqueId: string | undefined
    if (params.thumbnail != null) {
      if (params.type !== "video" && params.type !== "document") {
        throw new Error("uploadFile: thumbnails are only valid for video or document uploads")
      }
      const thumbnail = await this.uploads.upload({
        source: toUploadSource(params.thumbnail),
        fileName: normalizeUploadFileName(params.thumbnailFileName, "photo"),
        mimeType: resolveUploadContentType("photo", params.thumbnailContentType),
        kind: UploadKind.PHOTO,
        signal: params.signal,
      })
      thumbnailFileUniqueId = thumbnail.fileUniqueId
    }
    const metadata = params.type === "video"
      ? {
          kind: "video" as const,
          value: {
            width: normalizePositiveInt(params.width, "width") ?? defaultVideoWidth,
            height: normalizePositiveInt(params.height, "height") ?? defaultVideoHeight,
            duration: normalizePositiveInt(params.duration, "duration") ?? defaultVideoDuration,
            isAnimated: params.isAnimated ?? false,
            hasAudio: params.hasAudio,
          },
        }
      : params.type === "voice"
        ? {
            kind: "voice" as const,
            value: {
              duration: normalizePositiveInt(params.duration, "duration") ?? 0,
              waveform: params.waveform?.slice() ?? new Uint8Array(),
            },
          }
        : undefined
    const complete = await this.uploads.upload({
      source: toUploadSource(params.file),
      fileName,
      mimeType: fileContentType,
      kind: uploadKind(params.type),
      metadata,
      thumbnailFileUniqueId,
      clientUploadId: params.clientUploadId,
      signal: params.signal,
      onProgress: params.onProgress,
    })
    switch (complete.media.oneofKind) {
      case "photo": return { fileUniqueId: complete.fileUniqueId, photoId: complete.media.photo.id }
      case "video": return { fileUniqueId: complete.fileUniqueId, videoId: complete.media.video.id }
      case "document": return { fileUniqueId: complete.fileUniqueId, documentId: complete.media.document.id }
      case "voice": return { fileUniqueId: complete.fileUniqueId, voiceId: complete.media.voice.id }
      default: throw new Error("uploadFile: server returned no typed media result")
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

  async setBotPresenceState(params: InlineSdkSetBotPresenceStateParams): Promise<void> {
    const peerId = this.inputPeerFromTarget(params, "setBotPresenceState")
    await this.invoke(Method.SET_BOT_PRESENCE_STATE, {
      oneofKind: "setBotPresenceState",
      setBotPresenceState: {
        peerId,
        state: {
          kind: botPresenceStateKind(params.kind),
          ...(params.comment ? { comment: params.comment } : {}),
        },
      },
    })
  }

  async invokeMessageAction(params: InlineSdkInvokeMessageActionParams): Promise<{ interactionId: bigint }> {
    const peerId = this.inputPeerFromTarget(params, "invokeMessageAction")
    const actionId = params.actionId.trim()
    if (!actionId) {
      throw new Error("invokeMessageAction: `actionId` must be non-empty")
    }

    const result = await this.invoke(Method.INVOKE_MESSAGE_ACTION, {
      oneofKind: "invokeMessageAction",
      invokeMessageAction: {
        peerId,
        messageId: asInlineId(params.messageId, "messageId"),
        actionId,
      },
    })

    return {
      interactionId: result.invokeMessageAction.interactionId,
    }
  }

  async answerMessageAction(params: InlineSdkAnswerMessageActionParams): Promise<void> {
    await this.invoke(Method.ANSWER_MESSAGE_ACTION, {
      oneofKind: "answerMessageAction",
      answerMessageAction: {
        interactionId: asInlineId(params.interactionId, "interactionId"),
        ...(params.ui != null ? { ui: params.ui } : {}),
      },
    })
  }

  async getPeerBots(params: { chatId: InlineIdLike; userId?: never } | { userId: InlineIdLike; chatId?: never }) {
    const result = await this.invoke(Method.GET_PEER_BOTS, {
      oneofKind: "getPeerBots",
      getPeerBots: { peerId: this.inputPeerFromTarget(params, "getPeerBots") },
    })
    return result.getPeerBots
  }

  async getMyBotCapabilities(): Promise<{ capabilities: BotCapability[] }> {
    const result = await this.invoke(Method.GET_MY_BOT_CAPABILITIES, {
      oneofKind: "getMyBotCapabilities",
      getMyBotCapabilities: {},
    })
    return { capabilities: result.getMyBotCapabilities.capabilities }
  }

  async setMyBotCapabilities(
    params: InlineSdkSetMyBotCapabilitiesParams,
  ): Promise<{ capabilities: BotCapability[] }> {
    this.desiredBotCapabilities = params.capabilities.map((capability) => ({ ...capability }))
    this.desiredBotCapabilitiesRevision += 1
    return await this.registerDesiredBotCapabilities()
  }

  private async registerDesiredBotCapabilities(): Promise<{ capabilities: BotCapability[] }> {
    if (this.botCapabilitiesRegistrationInFlight) {
      const result = await this.botCapabilitiesRegistrationInFlight
      return this.registeredBotCapabilitiesRevision < this.desiredBotCapabilitiesRevision
        ? await this.registerDesiredBotCapabilities()
        : result
    }
    const capabilities = this.desiredBotCapabilities
    if (capabilities == null) return { capabilities: [] }
    const revision = this.desiredBotCapabilitiesRevision
    const registration = this.invoke(Method.SET_MY_BOT_CAPABILITIES, {
      oneofKind: "setMyBotCapabilities",
      setMyBotCapabilities: { capabilities },
    }).then((result) => {
      this.registeredBotCapabilitiesRevision = Math.max(this.registeredBotCapabilitiesRevision, revision)
      return { capabilities: result.setMyBotCapabilities.capabilities }
    })
    this.botCapabilitiesRegistrationInFlight = registration
    let result: { capabilities: BotCapability[] }
    try {
      result = await registration
    } finally {
      if (this.botCapabilitiesRegistrationInFlight === registration) {
        this.botCapabilitiesRegistrationInFlight = null
      }
    }
    return this.registeredBotCapabilitiesRevision < this.desiredBotCapabilitiesRevision
      ? await this.registerDesiredBotCapabilities()
      : result
  }

  async deleteMyBotCapabilities(): Promise<void> {
    await this.setMyBotCapabilities({ capabilities: [] })
  }

  async requestBotChatSettings(
    params: InlineSdkRequestBotChatSettingsParams,
  ): Promise<{ response: BotChatSettingsResponse }> {
    const result = await this.invoke(Method.REQUEST_BOT_CHAT_SETTINGS, {
      oneofKind: "requestBotChatSettings",
      requestBotChatSettings: {
        peerId: this.inputPeerFromTarget(params, "requestBotChatSettings"),
        botUserId: asInlineId(params.botUserId, "botUserId"),
        version: params.version ?? 1,
      },
    })
    const response = result.requestBotChatSettings.response
    if (!response) throw new Error("requestBotChatSettings: missing response")
    return { response }
  }

  async invokeBotChatSettingsItem(
    params: InlineSdkInvokeBotChatSettingsItemParams,
  ): Promise<{ response: BotChatSettingsResponse }> {
    const itemId = params.itemId.trim()
    const documentRevision = params.documentRevision.trim()
    if (!itemId || !documentRevision) {
      throw new Error("invokeBotChatSettingsItem: `itemId` and `documentRevision` must be non-empty")
    }
    const result = await this.invoke(Method.INVOKE_BOT_CHAT_SETTINGS_ITEM, {
      oneofKind: "invokeBotChatSettingsItem",
      invokeBotChatSettingsItem: {
        peerId: this.inputPeerFromTarget(params, "invokeBotChatSettingsItem"),
        botUserId: asInlineId(params.botUserId, "botUserId"),
        version: params.version ?? 1,
        itemId,
        value: params.value,
        documentRevision,
      },
    })
    const response = result.invokeBotChatSettingsItem.response
    if (!response) throw new Error("invokeBotChatSettingsItem: missing response")
    return { response }
  }

  /** Bot settings are ordinary user-visible configuration. Never include secrets. */
  async answerBotChatSettings(params: InlineSdkAnswerBotChatSettingsParams): Promise<void> {
    await this.invoke(Method.ANSWER_BOT_CHAT_SETTINGS, {
      oneofKind: "answerBotChatSettings",
      answerBotChatSettings: {
        requestId: asInlineId(params.requestId, "requestId"),
        response: params.response,
      },
    })
  }

  // TODO(bot-chat-settings): add bot-initiated transient document replacement after V1.

  // Raw RPC invocation escape hatch. Validates method/input/result when the SDK
  // has a mapping for the method; otherwise behaves like unchecked raw.
  async invokeRaw(
    method: Method,
    input: RpcCall["input"] = { oneofKind: undefined },
    options?: RpcCallOptions,
  ): Promise<RpcResult["result"]> {
    if (hasMethodMapping(method)) {
      this.assertMethodInputMatch(method, input)
    }
    const result = await this.callRpcWithSemanticPolicy(method, input, options)
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
    options?: RpcCallOptions,
  ): Promise<RpcResult["result"]> {
    return await this.callRpcWithSemanticPolicy(method, input, options)
  }

  async invoke<M extends MappedMethod>(
    method: M,
    input: RpcInputForMethod<M>,
    options?: RpcCallOptions,
  ): Promise<RpcResultForMethod<M>> {
    this.assertMethodInputMatch(method, input)
    const result = await this.callRpcWithSemanticPolicy(method, input, options)
    this.assertMethodResultMatch(method, result)
    return result
  }

  private async callRpcWithSemanticPolicy(
    method: Method,
    input: RpcCall["input"],
    options?: RpcCallOptions,
  ): Promise<RpcResult["result"]> {
    if (this.closed) throw new Error("SDK client is closed; create a new InlineSdkClient to reconnect")
    if (this.logoutInProgress && method !== Method.LOG_OUT) {
      throw new Error("logout in progress")
    }
    return await this.protocol.callRpc(method, input, {
      ...options,
      reconnectPolicy: options?.reconnectPolicy ?? reconnectPolicyForRpc(method, input),
    })
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
          case "authenticationError":
            this.onAuthenticationError(event.error)
            break
          case "updates":
            // ProtocolClient has already handed this wire-ordered batch to the
            // SDK update owner before a following RPC result can complete.
            break
          case "bot":
            await this.onBotEvent(event.bot)
            break
          case "rpcError":
          case "rpcResult":
          case "ack":
          case "connecting":
            break
        }
      }
    })().catch((error) => {
      const failure = error instanceof Error ? error : new Error("listener-crashed")
      this.log.error?.("SDK listener crashed", failure)
      this.started = false
      this.closed = true
      this.rejectOpen(failure)
      this.eventStream.fail(failure)
      void this.protocol.stopTransport().catch((stopError) => {
        this.log.error?.("Failed to stop transport after SDK listener failure", stopError)
      })
    })
  }

  private onAuthenticationError(error: InlineSdkAuthenticationError) {
    if (this.authenticationError) return
    this.authenticationError = error
    this.started = false
    this.rejectOpen(error)
    this.eventStream.close()

    try {
      this.options.onAuthenticationError?.(error)
    } catch (callbackError) {
      this.log.error?.("Authentication error callback failed", callbackError)
    }
  }

  private async onOpen() {
    this.requestCatchUpUser()
    for (const bucket of this.degradedUpdateBuckets.values()) {
      this.requestCatchUpForDegradedBucket(bucket)
    }

    this.openResolver?.()
    this.openResolver = null
    this.openRejecter = null

    // Best-effort: do not block `connect()` on cursor initialization.
    void this.initializeDateCursor()
    if (this.desiredBotCapabilities != null) {
      void this.registerDesiredBotCapabilities().catch((error) => {
        this.log.warn?.("Failed to restore bot capabilities after reconnect", error)
      })
    }
  }

  private onBotEvent(event: BotEvent): void {
    switch (event.event.oneofKind) {
      case "chatSettingsRequested": {
        const request = event.event.chatSettingsRequested
        void this.deliverEvent({
          kind: "bot.chatSettings.request",
          requestId: request.requestId,
          chatId: request.chatId,
          actorUserId: request.actorUserId,
          version: request.version,
        })
        return
      }
      case "chatSettingsItemInvoked": {
        const request = event.event.chatSettingsItemInvoked
        void this.deliverEvent({
          kind: "bot.chatSettings.item.invoke",
          requestId: request.requestId,
          chatId: request.chatId,
          actorUserId: request.actorUserId,
          version: request.version,
          itemId: request.itemId,
          value: request.value,
          documentRevision: request.documentRevision,
        })
        return
      }
      default:
        return
    }
  }

  private async initializeDateCursor() {
    if (this.discoveryInFlight) return this.discoveryInFlight
    if (this.discoveryCommitInFlight) return this.discoveryCommitInFlight

    const round: DiscoveryRound = {
      resultReceived: false,
      collectingHints: true,
      committing: false,
      observedHint: false,
      targets: new Map(),
    }
    this.discoveryRound = round

    const task = this.runDateCursorDiscovery(round)
      .finally(() => {
        if (this.discoveryInFlight === task) this.discoveryInFlight = null
      })
    this.discoveryInFlight = task
    return task
  }

  private async runDateCursorDiscovery(round: DiscoveryRound) {
    const date = this.state.dateCursor ?? nowSeconds()
    try {
      const result = await this.invoke(Method.GET_UPDATES_STATE, {
        oneofKind: "getUpdatesState",
        getUpdatesState: GetUpdatesStateInput.create({ date }),
      }, { timeoutMs: 1500 })
      const state = result.getUpdatesState as typeof result.getUpdatesState & { updatesFound?: boolean }
      round.checkpoint = state.date
      round.updatesFound = state.updatesFound
      round.resultReceived = true
      // ProtocolClient does not complete this RPC until every earlier
      // wire-ordered update batch has reached this owner. Hints observed after
      // this point belong to another server event, never to this checkpoint.
      round.collectingHints = false
      this.tryCommitDiscoveryRound(round)
    } catch (error) {
      // Not all deployments may support this yet; treat as best-effort.
      this.log.warn?.("GET_UPDATES_STATE failed (continuing without date cursor)", error)
      if (this.discoveryRound === round) this.discoveryRound = null
    }
  }

  private tryCommitDiscoveryRound(round: DiscoveryRound) {
    if (this.discoveryRound !== round || !round.resultReceived || round.checkpoint == null) return
    if (round.committing) return

    const targets = [...round.targets.values()]
    const allTargetsSatisfied = targets.every((target) => target.satisfied)
    if (round.updatesFound === true && (!round.observedHint || !allTargetsSatisfied)) return
    if (round.updatesFound !== false && round.updatesFound !== true) return
    if (!allTargetsSatisfied) return

    round.committing = true
    const previousDateCursor = this.state.dateCursor
    this.state.dateCursor = round.checkpoint
    this.scheduleStateSave()
    const commit = this.flushStateSave()
      .then((saved) => {
        if (this.discoveryRound !== round) return
        if (saved) {
          this.discoveryRound = null
          return
        }

        // A checkpoint is not committed until its state-store write succeeds.
        // Restore the old in-memory cursor so the next reconnect retries the
        // same discovery date rather than skipping over an unpersisted round.
        this.state.dateCursor = previousDateCursor
        this.scheduleStateSave()
        this.discoveryRound = null
        this.log.warn?.("Failed to persist discovery checkpoint; preserving previous date cursor")
      })
      .finally(() => {
        if (this.discoveryCommitInFlight === commit) this.discoveryCommitInFlight = null
        round.committing = false
      })
    this.discoveryCommitInFlight = commit
  }

  private registerDiscoveryHint(bucket: InlineSdkUpdateBucketRef, updateSeq: number) {
    const round = this.discoveryRound
    if (!round || !round.collectingHints) return

    round.observedHint = true
    const key = this.updateBucketKey(bucket)
    const existing = round.targets.get(key)
    const through = updateSeq > 0
    const requirement = existing?.requirement === "latest" || !through ? "latest" : "through"
    const seq = requirement === "through"
      ? Math.max(existing?.seq ?? 0, updateSeq)
      : undefined
    const target: DiscoveryTarget = existing
      ? { ...existing, bucket: { ...existing.bucket, ...bucket }, requirement, ...(seq != null ? { seq } : {}) }
      : { bucket, requirement, ...(seq != null ? { seq } : {}), satisfied: false }
    round.targets.set(key, target)

    if (requirement === "through" && seq != null && this.bucketCursor(bucket) >= seq) {
      target.satisfied = true
    }
    this.tryCommitDiscoveryRound(round)
  }

  private bucketCursor(bucket: InlineSdkUpdateBucketRef): number {
    switch (bucket.kind) {
      case "user": return this.state.lastUserSeq ?? 0
      case "chat": return this.state.lastSeqByChatId?.[bucket.chatId.toString()] ?? 0
      case "space": return this.state.lastSeqBySpaceId?.[bucket.spaceId.toString()] ?? 0
    }
  }

  private satisfyDiscoveryBucket(bucket: InlineSdkUpdateBucketRef, appliedSeq?: number) {
    const round = this.discoveryRound
    if (!round) return
    const target = round.targets.get(this.updateBucketKey(bucket))
    if (!target) return
    target.satisfied = target.requirement === "latest" ||
      (target.seq != null && (appliedSeq ?? this.bucketCursor(bucket)) >= target.seq)
    this.tryCommitDiscoveryRound(round)
  }

  private satisfyDiscoveryThroughCursor(bucket: InlineSdkUpdateBucketRef, seq: number) {
    const round = this.discoveryRound
    if (!round) return
    const target = round.targets.get(this.updateBucketKey(bucket))
    if (!target || target.satisfied || target.requirement !== "through" || target.seq == null) return
    if (seq >= target.seq) {
      target.satisfied = true
      this.tryCommitDiscoveryRound(round)
    }
  }

  private onUpdates(updates: Update[]) {
    for (const update of updates) {
      const handled = this.handleUpdate(update, { source: "live" })
      if (handled == null && !this.isEphemeralUpdate(update)) {
        const buckets = this.bucketForRawUpdate(update)
        if (buckets.length > 0) {
          for (const bucket of buckets) {
            this.fenceLiveCursor(bucket)
            if (this.isProjectedUpdateKind(update)) {
              this.markUpdateBucketDegraded(bucket)
              this.log.warn?.("Malformed projected live update; bucket remains degraded and cursor is fenced", {
                bucket: this.updateBucketKey(bucket),
                updateKind: update.update.oneofKind,
              })
            } else {
              this.log.debug?.("Unprojected durable live update; reconciling its sequence as a no-op", {
                bucket: this.updateBucketKey(bucket),
                updateKind: update.update.oneofKind,
              })
            }
            this.requestCatchUpForRawUpdate(bucket, update)
          }
        } else {
          this.log.warn?.("Unsupported durable live update without a provable bucket identity; requesting targeted discovery", {
            updateKind: update.update.oneofKind,
          })
          void this.initializeDateCursor()
        }
      }
    }
  }

  private handleUpdate(
    update: Update,
    options?: { source?: UpdateSource; bucket?: InlineSdkUpdateBucketRef },
  ): Promise<boolean> | null {
    const seq = update.seq ?? 0
    const date = update.date ?? 0n
    const deliver = (event: InlineInboundEvent, onApplied?: () => void) =>
      this.deliverEvent(event, onApplied, options?.source)

    switch (update.update.oneofKind) {
      case "newMessage": {
        const message = update.update.newMessage.message
        if (!message) return null
        if (message.peerId != null && this.isReliableChatPeer(message.peerId)) {
          this.rememberChatPeer(message.chatId, message.peerId)
        }
        return deliver({
          kind: "message.new",
          chatId: message.chatId,
          message,
          seq,
          date,
        }, () => this.bumpChatSeq(message.chatId, seq, options?.source))
      }

      case "editMessage": {
        const message = update.update.editMessage.message
        if (!message) return null
        if (message.peerId != null && this.isReliableChatPeer(message.peerId)) {
          this.rememberChatPeer(message.chatId, message.peerId)
        }
        return deliver({
          kind: "message.edit",
          chatId: message.chatId,
          message,
          seq,
          date,
        }, () => this.bumpChatSeq(message.chatId, seq, options?.source))
      }

      case "deleteMessages": {
        const payload = update.update.deleteMessages
        const chatId = this.chatIdForPeerScopedUpdate(payload.peerId, options?.bucket)
        if (!chatId) {
          this.log.warn?.("Unable to resolve deleteMessages update to one chat bucket", {
            source: options?.source ?? "live",
            peerKind: payload.peerId?.type.oneofKind ?? "missing",
          })
          return null
        }
        return deliver({
          kind: "message.delete",
          chatId,
          messageIds: payload.messageIds,
          seq,
          date,
        }, () => this.bumpChatSeq(chatId, seq, options?.source))
      }

      case "clearChatHistory": {
        const payload = update.update.clearChatHistory
        if (!payload.target) {
          this.log.warn?.("Skipping clearChatHistory update without target")
          return null
        }
        if (payload.target.oneofKind === "spaceId") {
          const spaceId = payload.target.spaceId
          return deliver({
            kind: "space.history.clear",
            spaceId,
            ...(payload.beforeDate != null ? { beforeDate: payload.beforeDate } : {}),
            deleteReplyThreads: payload.deleteReplyThreads,
            deletedChatIds: payload.deletedChatIds,
            orphanedChatIds: payload.orphanedChatIds,
            detachedChatIds: payload.detachedChatIds,
            seq,
            date,
          }, () => this.bumpSpaceSeq(spaceId, seq, options?.source))
        }

        const peerId = payload.target.oneofKind === "peerId" ? payload.target.peerId : undefined
        if (peerId) {
          const chatId = this.chatIdForPeerScopedUpdate(peerId, options?.bucket)
          if (!chatId) {
            this.log.warn?.("Unable to resolve clearChatHistory update to one chat bucket", {
              source: options?.source ?? "live",
              peerKind: peerId.type.oneofKind ?? "missing",
            })
            return null
          }
          return deliver({
            kind: "message.history.clear",
            chatId,
            ...(payload.beforeDate != null ? { beforeDate: payload.beforeDate } : {}),
            deleteReplyThreads: payload.deleteReplyThreads,
            deletedChatIds: payload.deletedChatIds,
            orphanedChatIds: payload.orphanedChatIds,
            detachedChatIds: payload.detachedChatIds,
            seq,
            date,
          }, () => this.bumpChatSeq(chatId, seq, options?.source))
        }

        this.log.warn?.("Skipping clearChatHistory update without peer target", peerId)
        return null
      }

      case "updateReaction": {
        const reaction = update.update.updateReaction.reaction
        if (!reaction) return null
        return deliver({
          kind: "reaction.add",
          chatId: reaction.chatId,
          reaction,
          seq,
          date,
        }, () => this.bumpChatSeq(reaction.chatId, seq, options?.source))
      }

      case "deleteReaction": {
        const payload = update.update.deleteReaction
        return deliver({
          kind: "reaction.delete",
          chatId: payload.chatId,
          emoji: payload.emoji,
          messageId: payload.messageId,
          userId: payload.userId,
          seq,
          date,
        }, () => this.bumpChatSeq(payload.chatId, seq, options?.source))
      }

      case "participantAdd": {
        const payload = update.update.participantAdd
        return deliver({
          kind: "chat.participant.add",
          chatId: payload.chatId,
          ...(payload.participant ? { participant: payload.participant } : {}),
          seq,
          date,
        }, () => this.bumpChatSeq(payload.chatId, seq, options?.source))
      }

      case "participantDelete": {
        const payload = update.update.participantDelete
        return deliver({
          kind: "chat.participant.delete",
          chatId: payload.chatId,
          userId: payload.userId,
          seq,
          date,
        }, () => this.bumpChatSeq(payload.chatId, seq, options?.source))
      }

      case "userAddedToChat": {
        if (options?.source === "live" && seq > 0) {
          this.fenceLiveCursor({ kind: "user" })
          this.registerDiscoveryHint({ kind: "user" }, seq)
          this.requestCatchUpUser(true)
          return Promise.resolve(true)
        }
        const payload = update.update.userAddedToChat
        return deliver({
          kind: "chat.access.added",
          chatId: payload.chatId,
          ...(payload.participant ? { participant: payload.participant } : {}),
          ...(payload.group ? { group: payload.group } : {}),
          seq,
          date,
        }, () => this.bumpUserSeq(seq, options?.source))
      }

      case "userRemovedFromChat": {
        const payload = update.update.userRemovedFromChat
        return deliver({
          kind: "chat.access.removed",
          chatId: payload.chatId,
          ...(payload.groupId != null ? { groupId: payload.groupId } : {}),
          seq,
          date,
        }, () => this.bumpUserSeq(seq, options?.source))
      }

      case "messageActionInvoked": {
        const payload = update.update.messageActionInvoked
        if (this.shouldSkipUserSeq(seq)) {
          // The persisted user cursor is the durable acknowledgement for this
          // already-seen update; do not turn a replay into a degraded bucket.
          return Promise.resolve(true)
        }
        return deliver({
          kind: "message.action.invoke",
          interactionId: payload.interactionId,
          chatId: payload.chatId,
          messageId: payload.messageId,
          actorUserId: payload.actorUserId,
          actionId: payload.actionId,
          data: payload.data,
          seq,
          date,
        }, () => this.bumpUserSeq(seq, options?.source))
      }

      case "messageActionAnswered": {
        const payload = update.update.messageActionAnswered
        if (this.shouldSkipUserSeq(seq)) {
          // The persisted user cursor is the durable acknowledgement for this
          // already-seen update; do not turn a replay into a degraded bucket.
          return Promise.resolve(true)
        }
        return deliver({
          kind: "message.action.answered",
          interactionId: payload.interactionId,
          ui: payload.ui,
          seq,
          date,
        }, () => this.bumpUserSeq(seq, options?.source))
      }

      case "chatHasNewUpdates": {
        const payload = update.update.chatHasNewUpdates
        const bucket: InlineSdkUpdateBucketRef = {
          kind: "chat",
          chatId: payload.chatId,
          ...(payload.peerId ? { peer: payload.peerId } : {}),
        }
        this.registerDiscoveryHint(bucket, payload.updateSeq)
        const delivery = deliver({
          kind: "chat.hasUpdates",
          chatId: payload.chatId,
          seq,
          date,
        })
        this.requestCatchUpChat({
          chatId: payload.chatId,
          peer: payload.peerId,
          ...(payload.updateSeq > 0 ? { updateSeq: payload.updateSeq } : {}),
        })
        return delivery
      }

      case "spaceHasNewUpdates": {
        const payload = update.update.spaceHasNewUpdates
        this.registerDiscoveryHint({ kind: "space", spaceId: payload.spaceId }, payload.updateSeq)
        const delivery = deliver({
          kind: "space.hasUpdates",
          spaceId: payload.spaceId,
          seq,
          date,
        })
        this.requestCatchUpSpace({
          spaceId: payload.spaceId,
          ...(payload.updateSeq > 0 ? { updateSeq: payload.updateSeq } : {}),
        })
        return delivery
      }

      default:
        return null
    }
  }

  private deliverEvent(
    event: InlineInboundEvent,
    onApplied?: () => void,
    source?: UpdateSource,
  ): Promise<boolean> {
    if (source === "live" && !this.prepareLiveEvent(event)) {
      return Promise.resolve(true)
    }

    let acknowledged: Promise<boolean>
    try {
      acknowledged = this.eventStream.send(event)
    } catch (error) {
      const bucket = this.bucketForEvent(event)
      if (bucket) {
        this.fenceLiveCursor(bucket)
        this.markUpdateBucketDegraded(bucket)
        this.requestCatchUpAfterEventOverflow(bucket, event)
      }
      this.log.warn?.("Inbound event buffer overflow; durable cursor remains unchanged and transport will recover", {
        bucket: bucket ? this.updateBucketKey(bucket) : "none",
        error: extractErrorMessage(error),
      })
      this.requestRecoveryReconnect("inbound-event-buffer-overflow")
      return Promise.resolve(false)
    }
    return acknowledged.then((applied) => {
      if (applied) {
        onApplied?.()
        if (source === "live") this.settleLiveEvent(event)
      } else if (source === "live" && this.started) {
        this.recoverLiveEvent(event, "consumer-did-not-apply")
      }
      return applied
    })
  }

  private bucketForEvent(event: InlineInboundEvent): InlineSdkUpdateBucketRef | undefined {
    switch (event.kind) {
      case "message.new":
      case "message.edit":
      case "message.delete":
      case "reaction.add":
      case "reaction.delete":
      case "chat.participant.add":
      case "chat.participant.delete":
        return { kind: "chat", chatId: event.chatId }
      case "chat.access.added":
      case "chat.access.removed":
        return { kind: "user" }
      case "message.history.clear":
        return event.chatId != null ? { kind: "chat", chatId: event.chatId } : { kind: "user" }
      case "space.history.clear":
      case "space.hasUpdates":
        return { kind: "space", spaceId: event.spaceId }
      case "message.action.answered":
      case "message.action.invoke":
        return { kind: "user" }
      case "chat.hasUpdates":
        return { kind: "chat", chatId: event.chatId }
      case "bot.chatSettings.request":
      case "bot.chatSettings.item.invoke":
        return undefined
    }
  }

  private sequencedBucketForEvent(event: InlineInboundEvent): InlineSdkUpdateBucketRef | undefined {
    switch (event.kind) {
      case "bot.chatSettings.request":
      case "bot.chatSettings.item.invoke":
      case "chat.hasUpdates":
      case "space.hasUpdates":
        return undefined
      default:
        return this.bucketForEvent(event)
    }
  }

  private hasBucketCursor(bucket: InlineSdkUpdateBucketRef): boolean {
    switch (bucket.kind) {
      case "user":
        return this.state.lastUserSeq != null
      case "chat":
        return Object.prototype.hasOwnProperty.call(
          this.state.lastSeqByChatId ?? {},
          bucket.chatId.toString(),
        )
      case "space":
        return Object.prototype.hasOwnProperty.call(
          this.state.lastSeqBySpaceId ?? {},
          bucket.spaceId.toString(),
        )
    }
  }

  private prepareLiveEvent(event: InlineInboundEvent): boolean {
    const bucket = this.sequencedBucketForEvent(event)
    if (!bucket) return true

    const seq = "seq" in event ? event.seq : 0
    if (!Number.isSafeInteger(seq) || seq <= 0) {
      this.fenceLiveCursor(bucket)
      this.markUpdateBucketDegraded(bucket)
      this.requestCatchUpForLiveEvent(bucket, event)
      this.log.warn?.("Durable live update has an invalid sequence; event was withheld for recovery", {
        bucket: this.updateBucketKey(bucket),
        seq,
      })
      return false
    }

    const key = this.updateBucketKey(bucket)
    const cursor = this.bucketCursor(bucket)
    const cursorKnown = this.hasBucketCursor(bucket)
    const admittedSeq = this.liveAdmittedSeqByBucket.get(key)

    if (cursorKnown && seq <= cursor) return false
    if (admittedSeq != null && seq <= admittedSeq) return false

    if (this.liveCursorFences.has(key)) {
      this.recoverLiveEvent(event, "bucket-repair-in-progress")
      return false
    }

    // Without a durable state owner, the first ordinary live event establishes
    // an in-memory baseline. A persisted client in discovery cannot do that
    // safely: an earlier server hint may still be in flight, so it recovers the
    // durable range first.
    if (!cursorKnown && admittedSeq == null &&
        (this.discoveryRound == null || this.options.state == null)) {
      this.liveAdmittedSeqByBucket.set(key, seq)
      return true
    }

    const admittedThrough = Math.max(cursor, admittedSeq ?? 0)
    if (seq === admittedThrough + 1) {
      this.liveAdmittedSeqByBucket.set(key, seq)
      return true
    }

    this.recoverLiveEvent(event, "sequence-gap")
    this.log.debug?.("Durable live update crossed a sequence gap; recovering through GET_UPDATES", {
      bucket: key,
      cursor,
      admittedThrough,
      receivedSeq: seq,
    })
    return false
  }

  private settleLiveEvent(event: InlineInboundEvent) {
    const bucket = this.sequencedBucketForEvent(event)
    if (!bucket) return
    const seq = "seq" in event ? event.seq : 0
    const key = this.updateBucketKey(bucket)
    if (this.liveAdmittedSeqByBucket.get(key) === seq && this.bucketCursor(bucket) >= seq) {
      this.liveAdmittedSeqByBucket.delete(key)
    }
  }

  private recoverLiveEvent(event: InlineInboundEvent, cause: string) {
    const bucket = this.sequencedBucketForEvent(event)
    if (!bucket) return
    const key = this.updateBucketKey(bucket)
    const seq = "seq" in event ? event.seq : 0
    const eventSeq = Number.isSafeInteger(seq) && seq > 0 ? seq : undefined
    const admittedSeq = this.liveAdmittedSeqByBucket.get(key)
    const updateSeq = eventSeq != null
      ? Math.max(eventSeq, admittedSeq ?? 0)
      : admittedSeq

    this.fenceLiveCursor(bucket)
    if (updateSeq != null) this.registerDiscoveryHint(bucket, updateSeq)
    this.requestCatchUpForLiveEvent(bucket, event, updateSeq)
    this.log.debug?.("Withheld live update until its bucket converges", {
      bucket: key,
      cause,
      updateSeq,
    })
  }

  private requestCatchUpForLiveEvent(
    bucket: InlineSdkUpdateBucketRef,
    event: InlineInboundEvent,
    updateSeq?: number,
  ) {
    switch (bucket.kind) {
      case "chat": {
        const peer = this.peerFromEvent(event) ?? this.persistedChatPeer(bucket.chatId)
        if (peer && this.isReliableChatPeer(peer)) {
          this.rememberChatPeer(bucket.chatId, peer)
          this.requestCatchUpChat({ chatId: bucket.chatId, peer, ...(updateSeq != null ? { updateSeq } : {}) })
        } else {
          this.markUpdateBucketDegraded(bucket)
          this.resolvePersistedChatPeer(bucket.chatId, updateSeq)
        }
        return
      }
      case "space":
        this.requestCatchUpSpace({ spaceId: bucket.spaceId, ...(updateSeq != null ? { updateSeq } : {}) })
        return
      case "user":
        this.requestCatchUpUser(true)
        return
    }
  }

  private requestRecoveryReconnect(cause: string) {
    if (!this.started || this.recoveryReconnectInFlight) return
    const reconnect = this.protocol.reconnect({ skipDelay: true, cause })
      .catch((error) => {
        this.log.warn?.("Failed to reconnect after inbound event buffer overflow", error)
      })
      .finally(() => {
        this.recoveryReconnectInFlight = null
      })
    this.recoveryReconnectInFlight = reconnect
  }

  private requestCatchUpAfterEventOverflow(bucket: InlineSdkUpdateBucketRef, event: InlineInboundEvent) {
    switch (bucket.kind) {
      case "chat": {
        const peer = this.peerFromEvent(event) ?? this.persistedChatPeer(bucket.chatId)
        if (peer && this.isReliableChatPeer(peer)) {
          this.rememberChatPeer(bucket.chatId, peer)
          this.requestCatchUpChat({ chatId: bucket.chatId, peer })
        } else {
          this.resolvePersistedChatPeer(bucket.chatId)
        }
        return
      }
      case "space":
        this.requestCatchUpSpace({ spaceId: bucket.spaceId })
        return
      case "user":
        this.requestCatchUpUser(true)
        return
    }
  }

  private requestCatchUpForDegradedBucket(bucket: InlineSdkUpdateBucketRef) {
    switch (bucket.kind) {
      case "chat":
        if (bucket.peer && this.isReliableChatPeer(bucket.peer)) {
          this.requestCatchUpChat({ chatId: bucket.chatId, peer: bucket.peer })
        } else {
          const persistedPeer = this.persistedChatPeer(bucket.chatId)
          if (persistedPeer) this.requestCatchUpChat({ chatId: bucket.chatId, peer: persistedPeer })
          else this.resolvePersistedChatPeer(bucket.chatId)
        }
        return
      case "space":
        this.requestCatchUpSpace({ spaceId: bucket.spaceId })
        return
      case "user":
        this.requestCatchUpUser(true)
        return
    }
  }

  private requestCatchUpForRawUpdate(bucket: InlineSdkUpdateBucketRef, update: Update) {
    const rawSeq = update.seq
    const updateSeq = rawSeq != null && Number.isSafeInteger(rawSeq) && rawSeq > 0 ? rawSeq : undefined
    switch (bucket.kind) {
      case "chat": {
        const peer = bucket.peer ?? this.persistedChatPeer(bucket.chatId)
        if (peer && this.isReliableChatPeer(peer)) {
          this.requestCatchUpChat({ chatId: bucket.chatId, peer, ...(updateSeq != null ? { updateSeq } : {}) })
        } else {
          this.resolvePersistedChatPeer(bucket.chatId, updateSeq)
        }
        return
      }
      case "space":
        this.requestCatchUpSpace({ spaceId: bucket.spaceId, ...(updateSeq != null ? { updateSeq } : {}) })
        return
      case "user":
        this.requestCatchUpUser(true)
        return
    }
  }

  private isEphemeralUpdate(update: Update): boolean {
    switch (update.update.oneofKind) {
      case "updateMessageId":
      case "updateComposeAction":
      case "updateUserStatus":
      case "updateReaction":
      case "deleteReaction":
      case "updateUserSettings":
      case "newMessageNotification":
      case "chatHasNewUpdates":
      case "spaceHasNewUpdates":
      case "botPresence":
        return true
      case undefined:
        return !(update.seq != null && update.seq > 0)
      default:
        return false
    }
  }

  private isProjectedUpdateKind(update: Update): boolean {
    switch (update.update.oneofKind) {
      case "newMessage":
      case "editMessage":
      case "deleteMessages":
      case "clearChatHistory":
      case "updateReaction":
      case "deleteReaction":
      case "participantAdd":
      case "participantDelete":
      case "userAddedToChat":
      case "userRemovedFromChat":
      case "messageActionInvoked":
      case "messageActionAnswered":
      case "chatHasNewUpdates":
      case "spaceHasNewUpdates":
        return true
      default:
        return false
    }
  }

  private bucketForRawUpdate(update: Update): InlineSdkUpdateBucketRef[] {
    switch (update.update.oneofKind) {
      // Current live producers for these variants use the chat bucket. The same
      // protobuf shapes may appear in a user GET_UPDATES page; that path already
      // has the authoritative bucket context and never calls this classifier.
      case "messageAttachment":
        return [{
          kind: "chat",
          chatId: update.update.messageAttachment.chatId,
          peer: update.update.messageAttachment.peerId,
        }]
      case "chatVisibility":
        return [this.chatBucket(update.update.chatVisibility.chatId)]
      case "chatInfo":
        return [this.chatBucket(update.update.chatInfo.chatId)]
      case "participantGroupAdd":
        return [this.chatBucket(update.update.participantGroupAdd.chatId)]
      case "participantGroupDelete":
        return [this.chatBucket(update.update.participantGroupDelete.chatId)]
      case "newChat": {
        const chat = update.update.newChat.chat
        return chat ? [this.chatBucket(chat.id, chat.peerId)] : []
      }
      case "chatMoved": {
        const chat = update.update.chatMoved.chat
        return chat ? [this.chatBucket(chat.id, chat.peerId)] : []
      }
      case "deleteChat":
        return this.chatBucketsForPeer(update.update.deleteChat.peerId)
      case "deleteMessages":
        return this.chatBucketsForPeer(update.update.deleteMessages.peerId)
      case "clearChatHistory": {
        const target = update.update.clearChatHistory.target
        if (target?.oneofKind === "peerId") return this.chatBucketsForPeer(target.peerId)
        if (target?.oneofKind === "spaceId") return [{ kind: "space", spaceId: target.spaceId }]
        return []
      }
      case "pinnedMessages":
        return this.chatBucketsForPeer(update.update.pinnedMessages.peerId)
      case "chatSkipPts":
        return [this.chatBucket(update.update.chatSkipPts.chatId)]

      case "spaceMemberDelete":
        return [{ kind: "space", spaceId: update.update.spaceMemberDelete.spaceId }]
      case "spaceMemberAdd": {
        const member = update.update.spaceMemberAdd.member
        return member ? [{ kind: "space", spaceId: member.spaceId }] : []
      }
      case "spaceMemberUpdate": {
        const member = update.update.spaceMemberUpdate.member
        return member ? [{ kind: "space", spaceId: member.spaceId }] : []
      }
      case "spaceSettings":
        return [{ kind: "space", spaceId: update.update.spaceSettings.spaceId }]

      case "dialogArchived":
      case "joinSpace":
      case "updateReadMaxId":
      case "markAsUnread":
      case "dialogNotificationSettings":
      case "chatOpen":
      case "dialogFollowMode":
      case "updatedUser":
      case "chatPermissions":
      case "dialogCollapsedMaxId":
      case "userAddedToChat":
      case "userRemovedFromChat":
        return [{ kind: "user" }]

      default:
        return []
    }
  }

  private chatBucket(chatId: bigint, peer?: Peer): InlineSdkUpdateBucketRef {
    return { kind: "chat", chatId, peer: peer ?? this.persistedChatPeer(chatId) }
  }

  private chatBucketsForPeer(peer: Peer | undefined): InlineSdkUpdateBucketRef[] {
    if (!peer) return []
    switch (peer.type.oneofKind) {
      case "chat": return [this.chatBucket(peer.type.chat.chatId, peer)]
      case "user": {
        const userId = peer.type.user.userId.toString()
        const matches: InlineSdkUpdateBucketRef[] = []
        for (const [chatIdKey, persisted] of Object.entries(this.state.chatPeerByChatId ?? {})) {
          if (persisted.kind !== "user" || persisted.id !== userId) continue
          try {
            const chatId = BigInt(chatIdKey)
            matches.push({ kind: "chat", chatId, peer })
          } catch {
            // Ignore malformed legacy keys; the state remains recoverable through normal repair.
          }
        }
        return matches.length === 1 ? matches : []
      }
      default: return []
    }
  }

  private chatIdForPeerScopedUpdate(
    peer: Peer | undefined,
    catchUpBucket?: InlineSdkUpdateBucketRef,
  ): bigint | null {
    if (catchUpBucket) {
      if (catchUpBucket.kind !== "chat") return null
      return catchUpBucket.chatId
    }

    if (peer?.type.oneofKind === "chat") return peer.type.chat.chatId
    const matches = this.chatBucketsForPeer(peer)
    return matches.length === 1 && matches[0]?.kind === "chat" ? matches[0].chatId : null
  }

  private peerFromEvent(event: InlineInboundEvent): Peer | undefined {
    switch (event.kind) {
      case "message.new":
      case "message.edit":
        return event.message.peerId
      default:
        return undefined
    }
  }

  private bumpChatSeq(chatId: bigint, seq: number, source?: UpdateSource) {
    if (source === "user" || source === "space" || source === "chat") return
    if (source === "live" && this.liveCursorFences.has(`chat:${chatId}`)) return
    if (!Number.isFinite(seq)) return
    if (!this.state.lastSeqByChatId) this.state.lastSeqByChatId = {}
    const key = chatId.toString()
    const prev = this.state.lastSeqByChatId[key] ?? 0
    if (seq > prev) {
      this.state.lastSeqByChatId[key] = seq
      this.scheduleStateSave()
    }
    this.satisfyDiscoveryThroughCursor({ kind: "chat", chatId }, seq)
  }

  private bumpSpaceSeq(spaceId: bigint, seq: number, source?: UpdateSource) {
    if (source === "user" || source === "space" || source === "chat") return
    if (source === "live" && this.liveCursorFences.has(`space:${spaceId}`)) return
    if (!Number.isFinite(seq)) return
    if (!this.state.lastSeqBySpaceId) this.state.lastSeqBySpaceId = {}
    const key = spaceId.toString()
    const prev = this.state.lastSeqBySpaceId[key] ?? 0
    if (seq > prev) {
      this.state.lastSeqBySpaceId[key] = seq
      this.scheduleStateSave()
    }
    this.satisfyDiscoveryThroughCursor({ kind: "space", spaceId }, seq)
  }

  private shouldSkipUserSeq(seq: number) {
    if (!Number.isFinite(seq)) return false
    const lastUserSeq = this.state.lastUserSeq ?? 0
    return seq > 0 && seq <= lastUserSeq
  }

  private bumpUserSeq(seq: number, source?: UpdateSource) {
    if (source === "user" || source === "space" || source === "chat") return
    if (source === "live" && this.liveCursorFences.has("user")) return
    if (!Number.isFinite(seq) || seq <= 0) return
    const prev = this.state.lastUserSeq ?? 0
    if (seq > prev) {
      this.state.lastUserSeq = seq
      this.scheduleStateSave()
    }
    this.satisfyDiscoveryThroughCursor({ kind: "user" }, seq)
  }

  private requestCatchUpUser(forceFromStart = false): Promise<void> | null {
    const lastUserSeq = this.state.lastUserSeq
    if (lastUserSeq == null && !this.options.catchUpUserFromStart && !forceFromStart) {
      return null
    }
    if (this.userCatchUpInFlight) {
      return this.userCatchUpInFlight
    }

    this.fenceLiveCursor({ kind: "user" })
    this.userCatchUpInFlight = this.doCatchUpUser(lastUserSeq ?? 0)
      .catch((error) => {
        this.markUpdateBucketDegraded({ kind: "user" })
        this.log.warn?.("GET_UPDATES user catch-up failed; bucket remains degraded", {
          error: extractErrorMessage(error),
        })
      })
      .finally(() => {
        this.userCatchUpInFlight = null
      })
    return this.userCatchUpInFlight
  }

  private async doCatchUpUser(startSeq: number) {
    let cursor = startSeq

    while (true) {
      const requestEndSeq = this.catchUpRequestEndSeq(cursor)
      const result = await this.invoke(Method.GET_UPDATES, {
        oneofKind: "getUpdates",
        getUpdates: GetUpdatesInput.create({
          bucket: UpdateBucket.create({
            type: {
              oneofKind: "user",
              user: {},
            },
          }),
          startSeq: BigInt(cursor),
          ...(requestEndSeq != null ? { seqEnd: BigInt(requestEndSeq) } : {}),
          totalLimit: defaultCatchUpTotalLimit,
          limit: defaultCatchUpPageLimit,
        }),
      })

      const payload = result.getUpdates
      const deliveredSeq = Number(payload.seq ?? 0n)
      if (!Number.isSafeInteger(deliveredSeq)) {
        this.markUpdateBucketDegraded({ kind: "user" })
        this.log.warn?.("GET_UPDATES user catch-up returned non-integer seq; aborting", { deliveredSeq })
        return
      }

      if (payload.resultType === GetUpdatesResult_ResultType.TOO_LONG) {
        const shouldContinue = this.shouldContinueBoundedCatchUp(cursor, deliveredSeq, requestEndSeq)
        const repaired = await this.repairUpdateBucketAuthoritatively(
          { kind: "user" },
          deliveredSeq,
          payload.date,
          !shouldContinue,
        )
        if (repaired && shouldContinue) {
          cursor = deliveredSeq
          continue
        }
        return
      }
      const requiresSnapshotRepair = this.validateCatchUpPage(payload, cursor, { kind: "user" })
      if (requiresSnapshotRepair == null) return
      if (requiresSnapshotRepair) {
        if (this.options.repairUpdatesBucket) {
          await this.repairUpdateBucketAuthoritatively({ kind: "user" }, deliveredSeq, payload.date)
          return
        }
        this.log.warn?.("GET_UPDATES advanced past a snapshot-repair marker without a host snapshot owner", {
          bucket: "user",
          deliveredSeq,
        })
      }
      if (deliveredSeq <= cursor && !payload.final) {
        this.markUpdateBucketDegraded({ kind: "user" })
        this.log.warn?.("GET_UPDATES user catch-up made no progress; bucket remains degraded", {
          cursor,
          deliveredSeq,
        })
        return
      }

      if (!await this.acceptCatchUpUpdates(payload.updates, "user", { kind: "user" })) return

      this.bumpUserSeq(deliveredSeq)
      this.scheduleStateSave()

      if (payload.final) {
        if (this.shouldContinueBoundedCatchUp(cursor, deliveredSeq, requestEndSeq)) {
          cursor = deliveredSeq
          continue
        }
        this.satisfyDiscoveryBucket({ kind: "user" }, deliveredSeq)
        this.clearUpdateBucketDegraded({ kind: "user" })
        return
      }
      cursor = deliveredSeq
    }
  }

  private requestCatchUpChat(params: { chatId: bigint; peer?: Peer; updateSeq?: number }): Promise<void> {
    if (params.peer) this.rememberChatPeer(params.chatId, params.peer)
    this.fenceLiveCursor({ kind: "chat", chatId: params.chatId, peer: params.peer })
    const previous = this.catchUpRequestedByChatId.get(params.chatId)
    this.catchUpRequestedByChatId.set(params.chatId, {
      ...(params.updateSeq != null || previous?.endSeq != null
        ? { endSeq: Math.max(previous?.endSeq ?? 0, params.updateSeq ?? 0) }
        : {}),
      peer: params.peer ?? previous?.peer,
      toLatest: previous?.toLatest === true || params.updateSeq == null,
    })

    const existing = this.catchUpInFlightByChatId.get(params.chatId)
    if (existing) return existing

    const task = this.drainCatchUpChat(params.chatId)
      .catch((error) => {
        this.catchUpRequestedByChatId.delete(params.chatId)
        this.markUpdateBucketDegraded({ kind: "chat", chatId: params.chatId, peer: params.peer })
        this.log.warn?.("GET_UPDATES chat catch-up failed; bucket remains degraded", {
          chatId: params.chatId.toString(),
          error: extractErrorMessage(error),
        })
      })
      .finally(() => {
        this.catchUpInFlightByChatId.delete(params.chatId)
      })
    this.catchUpInFlightByChatId.set(params.chatId, task)
    return task
  }

  private async drainCatchUpChat(chatId: bigint) {
    const key = chatId.toString()

    while (true) {
      const request = this.catchUpRequestedByChatId.get(chatId)
      if (!request) return

      const lastSeq = this.state.lastSeqByChatId?.[key]
      const endSeq = request.toLatest ? undefined : request.endSeq
      const startSeq = lastSeq ?? 0
      if (endSeq != null && endSeq <= startSeq) {
        this.satisfyDiscoveryThroughCursor({ kind: "chat", chatId }, startSeq)
        this.clearUpdateBucketDegraded({ kind: "chat", chatId, peer: request.peer })
        this.catchUpRequestedByChatId.delete(chatId)
        return
      }

      const stop = await this.doCatchUpChat(chatId, request.peer, startSeq, endSeq)
      if (stop) {
        if (this.catchUpRequestedByChatId.get(chatId) !== request) continue
        this.catchUpRequestedByChatId.delete(chatId)
        return
      }

      const latest = this.catchUpRequestedByChatId.get(chatId)
      const syncedSeq = this.state.lastSeqByChatId?.[key] ?? 0
      if (!latest || (latest.endSeq != null && latest.endSeq <= syncedSeq)) {
        this.catchUpRequestedByChatId.delete(chatId)
        return
      }
    }
  }

  private async doCatchUpChat(chatId: bigint, peer: Peer | undefined, startSeq: number, endSeq?: number): Promise<boolean> {
    let cursor = startSeq

    while (endSeq == null || cursor < endSeq) {
      const requestEndSeq = this.catchUpRequestEndSeq(cursor, endSeq)
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
          ...(requestEndSeq != null ? { seqEnd: BigInt(requestEndSeq) } : {}),
          totalLimit: defaultCatchUpTotalLimit,
          limit: defaultCatchUpPageLimit,
        }),
      })

      const payload = result.getUpdates

      if (payload.resultType === GetUpdatesResult_ResultType.TOO_LONG) {
        const deliveredSeq = Number(payload.seq ?? 0n)
        if (endSeq != null && requestEndSeq != null && deliveredSeq !== requestEndSeq) {
          this.markUpdateBucketDegraded({ kind: "chat", chatId, peer })
          this.log.warn?.("GET_UPDATES TOO_LONG pointer did not cover the requested chat target", {
            chatId: chatId.toString(),
            requestedEndSeq: requestEndSeq,
            deliveredSeq,
          })
          return true
        }
        const shouldContinue = this.shouldContinueBoundedCatchUp(cursor, deliveredSeq, requestEndSeq, endSeq)
        const repaired = await this.repairUpdateBucketAuthoritatively(
          { kind: "chat", chatId, peer },
          deliveredSeq,
          payload.date,
          !shouldContinue,
        )
        if (repaired && shouldContinue) {
          cursor = deliveredSeq
          continue
        }
        return true
      }

      const deliveredSeq = Number(payload.seq ?? 0n)
      if (!Number.isSafeInteger(deliveredSeq)) {
        this.markUpdateBucketDegraded({ kind: "chat", chatId, peer })
        this.log.warn?.("GET_UPDATES returned non-integer seq; aborting catch-up", { chatId: chatId.toString() })
        return true
      }
      const requiresSnapshotRepair = this.validateCatchUpPage(payload, cursor, { kind: "chat", chatId, peer })
      if (requiresSnapshotRepair == null) return true
      if (requiresSnapshotRepair) {
        if (this.options.repairUpdatesBucket) {
          await this.repairUpdateBucketAuthoritatively({ kind: "chat", chatId, peer }, deliveredSeq, payload.date)
          return true
        }
        this.log.warn?.("GET_UPDATES advanced past a snapshot-repair marker without a host snapshot owner", {
          bucket: this.updateBucketKey({ kind: "chat", chatId }),
          deliveredSeq,
        })
      }
      if (deliveredSeq <= cursor && !payload.final) {
        this.markUpdateBucketDegraded({ kind: "chat", chatId, peer })
        this.log.warn?.("GET_UPDATES made no progress; bucket remains degraded", {
          chatId: chatId.toString(),
          cursor,
          deliveredSeq,
        })
        return true
      }

      if (!await this.acceptCatchUpUpdates(payload.updates, "chat", { kind: "chat", chatId, peer })) return true

      // The acknowledged event stream resolves only after the consumer advances
      // past the event. Commit this slice after every update has therefore been
      // applied by the host, never merely after it was received from the server.
      this.bumpChatSeq(chatId, deliveredSeq)

      this.scheduleStateSave()

      if (payload.final) {
        if (this.shouldContinueBoundedCatchUp(cursor, deliveredSeq, requestEndSeq, endSeq)) {
          cursor = deliveredSeq
          continue
        }
        if (endSeq != null && deliveredSeq < endSeq) {
          this.markUpdateBucketDegraded({ kind: "chat", chatId, peer })
          this.log.warn?.("GET_UPDATES final chat page remained behind the requested target", {
            chatId: chatId.toString(),
            requestedEndSeq: endSeq,
            deliveredSeq,
          })
          return true
        }
        this.satisfyDiscoveryBucket({ kind: "chat", chatId, peer }, deliveredSeq)
        this.clearUpdateBucketDegraded({ kind: "chat", chatId, peer })
        return true
      }
      cursor = deliveredSeq
    }

    return false
  }

  private requestCatchUpSpace(params: { spaceId: bigint; updateSeq?: number }): Promise<void> {
    this.fenceLiveCursor({ kind: "space", spaceId: params.spaceId })
    const previous = this.catchUpRequestedBySpaceId.get(params.spaceId)
    this.catchUpRequestedBySpaceId.set(params.spaceId, {
      ...(params.updateSeq != null || previous?.endSeq != null
        ? { endSeq: Math.max(previous?.endSeq ?? 0, params.updateSeq ?? 0) }
        : {}),
      toLatest: previous?.toLatest === true || params.updateSeq == null,
    })

    const existing = this.catchUpInFlightBySpaceId.get(params.spaceId)
    if (existing) return existing

    const task = this.drainCatchUpSpace(params.spaceId)
      .catch((error) => {
        this.catchUpRequestedBySpaceId.delete(params.spaceId)
        this.markUpdateBucketDegraded({ kind: "space", spaceId: params.spaceId })
        this.log.warn?.("GET_UPDATES space catch-up failed; bucket remains degraded", {
          spaceId: params.spaceId.toString(),
          error: extractErrorMessage(error),
        })
      })
      .finally(() => {
        this.catchUpInFlightBySpaceId.delete(params.spaceId)
      })
    this.catchUpInFlightBySpaceId.set(params.spaceId, task)
    return task
  }

  private async drainCatchUpSpace(spaceId: bigint) {
    const key = spaceId.toString()

    while (true) {
      const request = this.catchUpRequestedBySpaceId.get(spaceId)
      if (!request) return

      const lastSeq = this.state.lastSeqBySpaceId?.[key]
      const endSeq = request.toLatest ? undefined : request.endSeq
      const startSeq = lastSeq ?? 0
      if (endSeq != null && endSeq <= startSeq) {
        this.satisfyDiscoveryThroughCursor({ kind: "space", spaceId }, startSeq)
        this.clearUpdateBucketDegraded({ kind: "space", spaceId })
        this.catchUpRequestedBySpaceId.delete(spaceId)
        return
      }

      const stop = await this.doCatchUpSpace(spaceId, startSeq, endSeq)
      if (stop) {
        if (this.catchUpRequestedBySpaceId.get(spaceId) !== request) continue
        this.catchUpRequestedBySpaceId.delete(spaceId)
        return
      }

      const latest = this.catchUpRequestedBySpaceId.get(spaceId)
      const syncedSeq = this.state.lastSeqBySpaceId?.[key] ?? 0
      if (!latest || (latest.endSeq != null && latest.endSeq <= syncedSeq)) {
        this.catchUpRequestedBySpaceId.delete(spaceId)
        return
      }
    }
  }

  private async doCatchUpSpace(spaceId: bigint, startSeq: number, endSeq?: number): Promise<boolean> {
    let cursor = startSeq

    while (endSeq == null || cursor < endSeq) {
      const requestEndSeq = this.catchUpRequestEndSeq(cursor, endSeq)
      const result = await this.invoke(Method.GET_UPDATES, {
        oneofKind: "getUpdates",
        getUpdates: GetUpdatesInput.create({
          bucket: UpdateBucket.create({
            type: {
              oneofKind: "space",
              space: {
                spaceId,
              },
            },
          }),
          startSeq: BigInt(cursor),
          ...(requestEndSeq != null ? { seqEnd: BigInt(requestEndSeq) } : {}),
          totalLimit: defaultCatchUpTotalLimit,
          limit: defaultCatchUpPageLimit,
        }),
      })

      const payload = result.getUpdates

      if (payload.resultType === GetUpdatesResult_ResultType.TOO_LONG) {
        const deliveredSeq = Number(payload.seq ?? 0n)
        if (endSeq != null && requestEndSeq != null && deliveredSeq !== requestEndSeq) {
          this.markUpdateBucketDegraded({ kind: "space", spaceId })
          this.log.warn?.("GET_UPDATES TOO_LONG pointer did not cover the requested space target", {
            spaceId: spaceId.toString(),
            requestedEndSeq: requestEndSeq,
            deliveredSeq,
          })
          return true
        }
        const shouldContinue = this.shouldContinueBoundedCatchUp(cursor, deliveredSeq, requestEndSeq, endSeq)
        const repaired = await this.repairUpdateBucketAuthoritatively(
          { kind: "space", spaceId },
          deliveredSeq,
          payload.date,
          !shouldContinue,
        )
        if (repaired && shouldContinue) {
          cursor = deliveredSeq
          continue
        }
        return true
      }

      const deliveredSeq = Number(payload.seq ?? 0n)
      if (!Number.isSafeInteger(deliveredSeq)) {
        this.markUpdateBucketDegraded({ kind: "space", spaceId })
        this.log.warn?.("GET_UPDATES space returned non-integer seq; aborting catch-up", {
          spaceId: spaceId.toString(),
        })
        return true
      }
      const requiresSnapshotRepair = this.validateCatchUpPage(payload, cursor, { kind: "space", spaceId })
      if (requiresSnapshotRepair == null) return true
      if (requiresSnapshotRepair) {
        if (this.options.repairUpdatesBucket) {
          await this.repairUpdateBucketAuthoritatively({ kind: "space", spaceId }, deliveredSeq, payload.date)
          return true
        }
        this.log.warn?.("GET_UPDATES advanced past a snapshot-repair marker without a host snapshot owner", {
          bucket: this.updateBucketKey({ kind: "space", spaceId }),
          deliveredSeq,
        })
      }
      if (deliveredSeq <= cursor && !payload.final) {
        this.markUpdateBucketDegraded({ kind: "space", spaceId })
        this.log.warn?.("GET_UPDATES space made no progress; bucket remains degraded", {
          spaceId: spaceId.toString(),
          cursor,
          deliveredSeq,
        })
        return true
      }

      if (!await this.acceptCatchUpUpdates(payload.updates, "space", { kind: "space", spaceId })) return true

      this.bumpSpaceSeq(spaceId, deliveredSeq)

      this.scheduleStateSave()

      if (payload.final) {
        if (this.shouldContinueBoundedCatchUp(cursor, deliveredSeq, requestEndSeq, endSeq)) {
          cursor = deliveredSeq
          continue
        }
        if (endSeq != null && deliveredSeq < endSeq) {
          this.markUpdateBucketDegraded({ kind: "space", spaceId })
          this.log.warn?.("GET_UPDATES final space page remained behind the requested target", {
            spaceId: spaceId.toString(),
            requestedEndSeq: endSeq,
            deliveredSeq,
          })
          return true
        }
        this.satisfyDiscoveryBucket({ kind: "space", spaceId }, deliveredSeq)
        this.clearUpdateBucketDegraded({ kind: "space", spaceId })
        return true
      }
      cursor = deliveredSeq
    }

    return false
  }

  private resolvePersistedChatPeer(chatId: bigint, updateSeq?: number): Promise<void> {
    const previous = this.peerResolutionRequestedByChatId.get(chatId)
    this.peerResolutionRequestedByChatId.set(chatId, {
      ...(updateSeq != null || previous?.endSeq != null
        ? { endSeq: Math.max(previous?.endSeq ?? 0, updateSeq ?? 0) }
        : {}),
      toLatest: previous?.toLatest === true || updateSeq == null,
    })
    const existing = this.peerResolutionInFlightByChatId.get(chatId)
    if (existing) return existing
    const task = this.getChat({ chatId })
      .then(async (chat) => {
        const peer = chat.peer
        if (!peer || !this.isReliableChatPeer(peer)) {
          throw new Error("getChat did not return a reliable peer identity")
        }
        this.rememberChatPeer(chatId, peer)
        const requested = this.peerResolutionRequestedByChatId.get(chatId)
        await this.requestCatchUpChat({
          chatId,
          peer,
          ...(requested && !requested.toLatest && requested.endSeq != null
            ? { updateSeq: requested.endSeq }
            : {}),
        })
      })
      .catch((error) => {
        this.markUpdateBucketDegraded({ kind: "chat", chatId })
        this.log.warn?.("Unable to resolve legacy chat peer; bucket remains degraded", {
          chatId: chatId.toString(),
          error: extractErrorMessage(error),
        })
      })
      .finally(() => {
        this.peerResolutionInFlightByChatId.delete(chatId)
        this.peerResolutionRequestedByChatId.delete(chatId)
      })
    this.peerResolutionInFlightByChatId.set(chatId, task)
    return task
  }

  private isReliableChatPeer(peer: Peer): boolean {
    switch (peer.type.oneofKind) {
      case "user": return typeof peer.type.user.userId === "bigint"
      case "chat": return typeof peer.type.chat.chatId === "bigint"
      default: return false
    }
  }

  private rememberChatPeer(chatId: bigint, peer: Peer) {
    let entry: { kind: "user" | "chat"; id: string } | undefined
    switch (peer.type.oneofKind) {
      case "user": entry = { kind: "user", id: peer.type.user.userId.toString() }; break
      case "chat": entry = { kind: "chat", id: peer.type.chat.chatId.toString() }; break
    }
    if (!entry) return
    const key = chatId.toString()
    if (!this.state.chatPeerByChatId) this.state.chatPeerByChatId = {}
    const previous = this.state.chatPeerByChatId[key]
    if (previous?.kind === entry.kind && previous.id === entry.id) return
    this.state.chatPeerByChatId[key] = entry
    this.scheduleStateSave()
  }

  private persistedChatPeer(chatId: bigint): Peer | undefined {
    const persisted = this.state.chatPeerByChatId?.[chatId.toString()]
    if (!persisted) return undefined
    try {
      const id = BigInt(persisted.id)
      if (persisted.kind === "user") return { type: { oneofKind: "user", user: { userId: id } } }
      if (persisted.kind === "chat") return { type: { oneofKind: "chat", chat: { chatId: id } } }
      return undefined
    } catch {
      return undefined
    }
  }

  private validateCatchUpPage(
    payload: GetUpdatesResult,
    startSeq: number,
    bucket: InlineSdkUpdateBucketRef,
  ): boolean | undefined {
    if (payload.resultType !== GetUpdatesResult_ResultType.SLICE &&
      payload.resultType !== GetUpdatesResult_ResultType.EMPTY) {
      this.markUpdateBucketDegraded(bucket)
      this.log.warn?.("GET_UPDATES returned an invalid page result type; bucket remains degraded", {
        bucket: this.updateBucketKey(bucket),
        resultType: payload.resultType,
      })
      return undefined
    }

    const deliveredSeq = Number(payload.seq)
    if (!Number.isSafeInteger(deliveredSeq) || deliveredSeq < startSeq) {
      this.markUpdateBucketDegraded(bucket)
      this.log.warn?.("GET_UPDATES page moved backwards or returned an invalid seq; bucket remains degraded", {
        bucket: this.updateBucketKey(bucket),
        startSeq,
        deliveredSeq,
      })
      return undefined
    }

    const accounted = new Set<number>()
    for (const update of payload.updates) {
      const seq = update.seq
      if (!Number.isSafeInteger(seq) || seq == null || seq <= startSeq || seq > deliveredSeq || accounted.has(seq)) {
        this.markUpdateBucketDegraded(bucket)
        this.log.warn?.("GET_UPDATES page included an invalid or duplicate update seq; bucket remains degraded", {
          bucket: this.updateBucketKey(bucket),
          seq,
        })
        return undefined
      }
      accounted.add(seq)
    }

    let requiresSnapshotRepair = false
    for (const skipped of payload.skippedSequences) {
      const seq = Number(skipped.seq)
      if (!Number.isSafeInteger(seq) || seq <= startSeq || seq > deliveredSeq || accounted.has(seq)) {
        this.markUpdateBucketDegraded(bucket)
        this.log.warn?.("GET_UPDATES page included an invalid or duplicate skipped seq; bucket remains degraded", {
          bucket: this.updateBucketKey(bucket),
          seq,
        })
        return undefined
      }
      accounted.add(seq)
      switch (skipped.reason) {
        case SyncSkippedSequence_Reason.IRRELEVANT_TO_BUCKET:
          break
        case SyncSkippedSequence_Reason.SNAPSHOT_REPAIR_REQUIRED:
          requiresSnapshotRepair = true
          break
        case SyncSkippedSequence_Reason.REASON_UNSPECIFIED:
        default:
          this.markUpdateBucketDegraded(bucket)
          this.log.warn?.("GET_UPDATES page included an unsupported skipped-sequence reason; bucket remains degraded", {
            bucket: this.updateBucketKey(bucket),
            reason: skipped.reason,
          })
          return undefined
      }
    }

    if (accounted.size !== deliveredSeq - startSeq) {
      this.markUpdateBucketDegraded(bucket)
      this.log.warn?.("GET_UPDATES page did not account for every advanced sequence; bucket remains degraded", {
        bucket: this.updateBucketKey(bucket),
        startSeq,
        deliveredSeq,
        accounted: accounted.size,
      })
      return undefined
    }
    return requiresSnapshotRepair
  }

  private catchUpRequestEndSeq(cursor: number, requestedEndSeq?: number): number | undefined {
    if (this.options.repairUpdatesBucket) return requestedEndSeq
    return Math.min(
      requestedEndSeq ?? maxDatabaseUpdateSequence,
      cursor + defaultCatchUpTotalLimit,
    )
  }

  private shouldContinueBoundedCatchUp(
    previousCursor: number,
    deliveredSeq: number,
    requestEndSeq?: number,
    requestedEndSeq?: number,
  ): boolean {
    if (this.options.repairUpdatesBucket || requestEndSeq == null) return false
    if (deliveredSeq <= previousCursor || deliveredSeq !== requestEndSeq) return false
    return requestedEndSeq == null
      ? requestEndSeq < maxDatabaseUpdateSequence
      : deliveredSeq < requestedEndSeq
  }

  private async repairUpdateBucketAuthoritatively(
    bucket: InlineSdkUpdateBucketRef,
    serverSeq: number,
    serverDate: bigint,
    finalize = true,
  ): Promise<boolean> {
    if (!Number.isSafeInteger(serverSeq) || serverSeq < 0) {
      this.markUpdateBucketDegraded(bucket)
      return false
    }
    const repair = this.options.repairUpdatesBucket
    if (!repair) {
      if (serverSeq <= this.bucketCursor(bucket)) {
        this.markUpdateBucketDegraded(bucket)
        this.log.warn?.("GET_UPDATES repair did not advance its bucket; bucket remains degraded", {
          bucket: this.updateBucketKey(bucket),
          serverSeq,
        })
        return false
      }
      switch (bucket.kind) {
        case "user": this.bumpUserSeq(serverSeq); break
        case "chat": this.bumpChatSeq(bucket.chatId, serverSeq); break
        case "space": this.bumpSpaceSeq(bucket.spaceId, serverSeq); break
      }
      this.scheduleStateSave()
      if (finalize) {
        this.satisfyDiscoveryBucket(bucket, serverSeq)
        this.clearUpdateBucketDegraded(bucket)
      }
      this.log.warn?.("GET_UPDATES could not replay a bounded range; advanced to its server-authoritative cursor", {
        bucket: this.updateBucketKey(bucket),
        serverSeq,
      })
      return true
    }

    try {
      const request: InlineSdkAuthoritativeRepairRequest = { bucket, serverSeq, serverDate }
      const result = await repair(request)
      if (!Number.isSafeInteger(result.appliedSeq) || result.appliedSeq < serverSeq) {
        throw new Error("authoritative repair returned a cursor behind server state")
      }
      switch (bucket.kind) {
        case "user": this.bumpUserSeq(result.appliedSeq); break
        case "chat": this.bumpChatSeq(bucket.chatId, result.appliedSeq); break
        case "space": this.bumpSpaceSeq(bucket.spaceId, result.appliedSeq); break
      }
      this.scheduleStateSave()
      this.satisfyDiscoveryBucket(bucket, result.appliedSeq)
      this.clearUpdateBucketDegraded(bucket)
      return true
    } catch (error) {
      this.markUpdateBucketDegraded(bucket)
      this.log.warn?.("Authoritative update repair failed; bucket remains degraded", {
        bucket: this.updateBucketKey(bucket),
        error: extractErrorMessage(error),
      })
      return false
    }
  }

  private async acceptCatchUpUpdates(
    updates: Update[],
    source: UpdateSource,
    bucket: InlineSdkUpdateBucketRef,
  ): Promise<boolean> {
    for (const update of updates) {
      if (update.update.oneofKind === "chatSkipPts" && source === "chat") {
        continue
      }
      if (update.update.oneofKind === undefined) {
        // protobuf-ts preserves unknown fields even though an older generated
        // oneof has no typed case for them. The surrounding GET_UPDATES page
        // still proves the sequence coverage, so older SDKs deliberately treat
        // this as a forward-compatible no-op and advance the page cursor.
        continue
      }
      const accepted = await this.handleUpdate(update, { source, bucket })
      if (accepted === true) continue

      if (accepted === false) {
        this.markUpdateBucketDegraded(bucket)
        this.log.warn?.("GET_UPDATES event was not acknowledged by the SDK host; cursor remains unchanged", {
          bucket: this.updateBucketKey(bucket),
          updateKind: update.update.oneofKind,
        })
        return false
      }

      if (!this.isProjectedUpdateKind(update)) {
        this.log.debug?.("GET_UPDATES advanced past an update this SDK does not project", {
          bucket: this.updateBucketKey(bucket),
          updateKind: update.update.oneofKind,
        })
        continue
      }

      this.log.warn?.("GET_UPDATES authoritatively advanced past an update the SDK could not project", {
        bucket: this.updateBucketKey(bucket),
        updateKind: update.update.oneofKind,
      })
    }
    return true
  }

  private markUpdateBucketDegraded(bucket: InlineSdkUpdateBucketRef) {
    this.degradedUpdateBuckets.set(this.updateBucketKey(bucket), bucket)
  }

  private fenceLiveCursor(bucket: InlineSdkUpdateBucketRef) {
    this.liveCursorFences.add(this.updateBucketKey(bucket))
  }

  private clearUpdateBucketDegraded(bucket: InlineSdkUpdateBucketRef) {
    const key = this.updateBucketKey(bucket)
    this.degradedUpdateBuckets.delete(key)
    this.liveCursorFences.delete(key)
    this.liveAdmittedSeqByBucket.delete(key)
  }

  private updateBucketKey(bucket: InlineSdkUpdateBucketRef): string {
    switch (bucket.kind) {
      case "user": return "user"
      case "chat": return `chat:${bucket.chatId}`
      case "space": return `space:${bucket.spaceId}`
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

  private clearHistoryTargetFromParams(params: InlineSdkClearChatHistoryParams): ClearChatHistoryInput["target"] {
    const hasChatId = params.chatId != null
    const hasUserId = params.userId != null
    const hasSpaceId = params.spaceId != null

    if ([hasChatId, hasUserId, hasSpaceId].filter(Boolean).length !== 1) {
      throw new Error("clearChatHistory: provide exactly one of `chatId`, `userId`, or `spaceId`")
    }

    if (hasSpaceId) {
      return { oneofKind: "spaceId", spaceId: asInlineId(params.spaceId as InlineIdLike, "spaceId") }
    }

    return { oneofKind: "peerId", peerId: this.inputPeerFromTarget(params, "clearChatHistory") }
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
    this.dirtyStateRevision++
    if (!this.started) return
    if (this.saveTimer) return
    this.saveTimer = setTimeout(() => {
      this.saveTimer = null
      void this.flushStateSave()
    }, 250)
  }

  private async flushStateSave(): Promise<boolean> {
    const store = this.options.state
    if (!store) return true

    if (this.saveTimer) {
      clearTimeout(this.saveTimer)
      this.saveTimer = null
    }

    if (this.saveInFlight) {
      const saved = await this.saveInFlight
      if (!saved) return false
      if (this.savedStateRevision >= this.dirtyStateRevision) return true
      if (this.saveInFlight) {
        return await this.saveInFlight
      }
    }

    this.saveInFlight = this.drainStateSaves(store).finally(() => {
      this.saveInFlight = null
    })

    return await this.saveInFlight
  }

  private async drainStateSaves(store: NonNullable<InlineSdkClientOptions["state"]>) {
    while (this.savedStateRevision < this.dirtyStateRevision) {
      const revision = this.dirtyStateRevision
      const snapshot = this.exportState()
      try {
        await store.save(snapshot)
      } catch (error) {
        this.log.warn?.("Failed to persist SDK state", error)
        return false
      }
      this.savedStateRevision = revision
    }
    return true
  }
}

async function settleWithin(
  operation: Promise<unknown>,
  timeoutMs: number,
  onTimeout: () => void,
): Promise<void> {
  let timeout: ReturnType<typeof setTimeout> | null = null
  const outcome = await Promise.race([
    operation.then(() => "settled" as const, () => "settled" as const),
    new Promise<"timeout">((resolve) => {
      timeout = setTimeout(() => resolve("timeout"), timeoutMs)
    }),
  ])
  if (timeout) clearTimeout(timeout)
  if (outcome === "timeout") onTimeout()
}

function toInputMedia(media: InlineSdkSendMessageMedia): {
  media:
    | { oneofKind: "photo"; photo: { photoId: bigint } }
    | { oneofKind: "video"; video: { videoId: bigint } }
    | { oneofKind: "document"; document: { documentId: bigint } }
    | { oneofKind: "voice"; voice: { voiceId: bigint } }
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
    case "voice":
      return {
        media: {
          oneofKind: "voice",
          voice: {
            voiceId: asInlineId(media.voiceId, "voiceId"),
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

function normalizeUploadFileName(raw: string | undefined, type: "photo" | "video" | "document" | "voice"): string {
  const trimmed = sanitizeUploadFileName(raw)
  if (trimmed) return trimmed
  switch (type) {
    case "photo":
      return "photo.jpg"
    case "video":
      return "video.mp4"
    case "document":
      return "document.bin"
    case "voice":
      return "voice.ogg"
  }
}

function resolveUploadContentType(type: "photo" | "video" | "document" | "voice", explicit: string | undefined): string {
  const trimmed = explicit?.trim()
  if (trimmed) return trimmed
  switch (type) {
    case "photo":
      return "image/jpeg"
    case "video":
      return "video/mp4"
    case "document":
      return "application/octet-stream"
    case "voice":
      return "audio/ogg"
  }
}

function uploadKind(type: "photo" | "video" | "document" | "voice"): UploadKind {
  switch (type) {
    case "photo": return UploadKind.PHOTO
    case "video": return UploadKind.VIDEO
    case "document": return UploadKind.DOCUMENT
    case "voice": return UploadKind.VOICE
  }
}

function toUploadSource(input: InlineSdkUploadFileParams["file"]): UploadByteSource {
  if (typeof SharedArrayBuffer !== "undefined" && input instanceof SharedArrayBuffer) {
    return uploadByteSource(new Uint8Array(input))
  }
  return uploadByteSource(input as Blob | Uint8Array | ArrayBuffer)
}

function toBlob(input: InlineSdkUploadFileParams["file"], type: string): Blob {
  if (input instanceof Blob) {
    return input.type === type ? input : new Blob([input], { type })
  }
  return new Blob([input], { type })
}

// Retained only as a reviewable compatibility seam until the legacy multipart API is removed.
// oxlint-disable-next-line no-unused-vars
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

// oxlint-disable-next-line no-unused-vars
function getBinaryInputSize(input: InlineSdkUploadFileParams["file"]): number {
  if (input instanceof Blob) return input.size
  if (input instanceof Uint8Array) return input.byteLength
  return input.byteLength
}

// oxlint-disable-next-line no-unused-vars
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

function normalizeKeepLastDays(value: number): number {
  if (!Number.isFinite(value) || !Number.isInteger(value) || value < 0 || value > 36_500) {
    throw new Error("clearChatHistory: `keepLastDays` must be 0 or a positive integer up to 36500")
  }
  return value
}

// oxlint-disable-next-line no-unused-vars
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

// oxlint-disable-next-line no-unused-vars
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

// oxlint-disable-next-line no-unused-vars
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

const resolveRealtimeV3Url = (baseUrl: string): string => {
  const url = new URL(baseUrl)
  url.protocol = url.protocol === "https:" ? "wss:" : "ws:"
  url.pathname = url.pathname.replace(/\/+$/, "") + "/realtime/v3"
  return url.toString()
}

// oxlint-disable-next-line no-unused-vars
const resolveUploadFileUrl = (baseUrl: string): URL => {
  const url = new URL(baseUrl)
  const basePath = url.pathname.replace(/\/+$/, "")
  url.pathname = `${basePath}/v1/uploadFile`
  return url
}

const hasMethodMapping = (method: Method): method is MappedMethod =>
  Object.prototype.hasOwnProperty.call(rpcInputKindByMethod, method) &&
  Object.prototype.hasOwnProperty.call(rpcResultKindByMethod, method)
