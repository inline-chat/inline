import { InlineSdkClient } from "@inline-chat/realtime-sdk"
import { createHttpRpcInvoker, type InlineRpcCallOptions, type InlineRpcInvoker } from "./rpc-invoker"
import {
  CreateChatInput,
  CreateSubthreadInput,
  ForwardMessagesInput,
  GetChatHistoryMode,
  GetChatHistoryInput,
  GetChatParticipantsInput,
  GetChatsInput,
  GetChatInput,
  GetMessagesInput,
  GetMeInput,
  GetSpaceMembersInput,
  GetSpaceInput,
  GetUsersInput,
  InputChatParticipant,
  InputPeer,
  ChatListKind,
  ChatListOrder,
  ChatListScope,
  Method,
  MessageSendMode,
  SearchMessagesInput,
  SearchMessagesFilter,
  SendMessageInput,
  type Chat,
  type Dialog,
  type GetChatsResult,
  type GetChatResult,
  type InputMedia,
  type Message,
  type RpcCall,
  type RpcResult,
  type Space,
  type Update,
  type User,
} from "@inline-chat/protocol/core"

type RpcInputKind = NonNullable<RpcCall["input"]["oneofKind"]>
type RpcInputOf<K extends RpcInputKind> = Extract<RpcCall["input"], { oneofKind: K }>
type RpcResultOf<K extends RpcInputKind> = Extract<RpcResult["result"], { oneofKind: K }>

const randomMessageId = (): bigint => {
  const bytes = new Uint8Array(8)
  globalThis.crypto.getRandomValues(bytes)
  const value = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength).getBigInt64(0, true)
  return value === 0n ? 1n : value
}

/** Same receipt extraction as the SDK's sendMessage. */
const firstMessageId = (updates: Update[] | undefined): bigint | null => {
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

export type InlineAllowedContext = {
  allowedSpaceIds: bigint[]
  allowDms?: boolean
  allowHomeThreads?: boolean
}

export class InlineAccessDeniedError extends Error {}

export type InlineAccountProfile = {
  id: bigint
  name?: string
  email?: string
  nickname?: string
}

export type InlineEligibleChat = {
  chatId: bigint
  title: string
  chatTitle: string
  kind: "dm" | "home_thread" | "space_chat"
  spaceId: bigint | null
  spaceName: string | null
  peerUserId: bigint | null
  peerDisplayName: string | null
  peerUsername: string | null
  archived: boolean
  pinned: boolean
  unreadCount: number
  readMaxId: bigint | null
  lastMessageId: bigint | null
  lastMessageDate: bigint | null
}

/** One server-scoped, ascending-ID page of the authorized conversation catalog (paged GetChats). */
export type InlineListChatsParams = {
  afterChatId?: bigint
  limit: number
  includeSubthreads?: boolean
  spaceId?: bigint
  kind?: InlineEligibleChat["kind"]
  unreadOnly?: boolean
}

export type InlineListChatsPage = {
  chats: InlineEligibleChat[]
  nextAfterChatId: bigint | null
}

export type InlineConversationCandidate = InlineEligibleChat & {
  score: number
  matchReasons: string[]
}

export type InlineConversationResolution = {
  query: string
  selected: InlineConversationCandidate | null
  candidates: InlineConversationCandidate[]
}

export type InlineConversationFilters = {
  spaceId?: bigint
  kind?: InlineEligibleChat["kind"]
  unreadOnly?: boolean
  sort?: "relevance" | "recent" | "unread"
}

export type InlineSpaceSummary = {
  id: bigint
  name: string
  creator: boolean
  date: bigint | null
  isPublic: boolean | null
  chatCount: number
  unreadCount: number
  lastMessageDate: bigint | null
}

export type InlinePersonSummary = {
  userId: bigint
  displayName: string
  username: string | null
  firstName: string | null
  lastName: string | null
  dmChatId: bigint | null
  spaceIds: bigint[]
  spaceNames: string[]
}

export type InlinePersonCandidate = InlinePersonSummary & {
  score: number
  matchReasons: string[]
}

export type InlineConversationDetails = {
  chat: InlineEligibleChat
  description: string | null
  emoji: string | null
  isPublic: boolean | null
  date: bigint | null
  createdBy: bigint | null
  parentChatId: bigint | null
  parentMessageId: bigint | null
  number: number | null
  pinnedMessageIds: bigint[]
  groupParticipantCount: number
  participants: InlinePersonSummary[]
}

export type InlineMessageContentFilter = "all" | "links" | "media" | "photos" | "videos" | "documents" | "files"

export type InlineRecentMessagesResult = {
  chat: InlineEligibleChat
  direction: "sent" | "all"
  scannedCount: number
  nextOffsetId: bigint | null
  messages: Message[]
  senderDisplayNames?: Record<string, string>
  /** Signed profile images for UI-only tool metadata, never message text. */
  senderAvatarUrls?: Record<string, string>
}

export type InlineSearchMessagesResult = {
  chat: InlineEligibleChat
  query: string | null
  content: InlineMessageContentFilter
  mode: "search" | "scan"
  scannedCount: number
  nextOffsetId: bigint | null
  messages: Message[]
  senderDisplayNames?: Record<string, string>
  /** Signed profile images for UI-only tool metadata, never message text. */
  senderAvatarUrls?: Record<string, string>
}

export type InlineForwardMessagesResult = {
  sourceChat: InlineEligibleChat
  destinationChat: InlineEligibleChat
  messages: Array<{ sourceMessageId: bigint; destinationMessageId: bigint }>
}

export type InlineUnreadMessagesResult = {
  scannedChats: number
  items: Array<{
    chat: InlineEligibleChat
    message: Message
  }>
}

export type InlineMessageContextResult = {
  chat: InlineEligibleChat
  anchorMessageId: bigint | null
  before: number
  after: number
  includeAnchor: boolean
  content: InlineMessageContentFilter
  messages: Message[]
}

export type InlineMessagesResult = {
  chat: InlineEligibleChat
  messages: Message[]
}

export type InlineUploadedMediaKind = "photo" | "video" | "document"

export type InlineUploadedMedia = {
  kind: InlineUploadedMediaKind
  id: bigint
}

export type InlineUploadFileResult = {
  fileUniqueId: string
  media: InlineUploadedMedia
}

export type InlineApi = {
  close(): Promise<void>
  getProfile(): Promise<InlineAccountProfile>
  listSpaces(params: { query?: string; limit?: number }): Promise<InlineSpaceSummary[]>
  searchPeople(params: { query?: string; limit?: number }): Promise<{ query: string | null; bestMatch: InlinePersonCandidate | null; items: InlinePersonCandidate[] }>
  getEligibleChats(params?: { includeSubthreads?: boolean }): Promise<InlineEligibleChat[]>
  /** Paged GetChats in ID order. Older InlineApi adapters can omit it. */
  listChats?(params: InlineListChatsParams): Promise<InlineListChatsPage>
  resolveConversation(query: string, limit: number, filters?: InlineConversationFilters): Promise<InlineConversationResolution>
  getConversation(params: { chatId?: bigint; userId?: bigint }): Promise<InlineConversationDetails>
  /** One logical tool read; older InlineApi adapters can retain separate reads. */
  openConversation?(params: { chatId: bigint; limit?: number }): Promise<{ details: InlineConversationDetails; history: InlineRecentMessagesResult }>
  messageContext(params: {
    chatId?: bigint
    userId?: bigint
    anchorMessageId?: bigint
    before?: number
    after?: number
    includeAnchor?: boolean
    content?: InlineMessageContentFilter
  }): Promise<InlineMessageContextResult>
  getMessages(params: {
    chatId?: bigint
    userId?: bigint
    messageIds: bigint[]
  }): Promise<InlineMessagesResult>
  recentMessages(params: {
    chatId?: bigint
    userId?: bigint
    direction?: "sent" | "all"
    limit?: number
    offsetId?: bigint
    since?: bigint
    until?: bigint
    unreadOnly?: boolean
    content?: InlineMessageContentFilter
    senderUserId?: bigint
    /** Recheck the target's current grant context without trusting discovery metadata. */
    freshChatAuthorization?: boolean
  }): Promise<InlineRecentMessagesResult>
  searchMessages(params: {
    chatId?: bigint
    userId?: bigint
    query?: string
    limit?: number
    offsetId?: bigint
    senderUserId?: bigint
    since?: bigint
    until?: bigint
    content?: InlineMessageContentFilter
  }): Promise<InlineSearchMessagesResult>
  unreadMessages(params: {
    limit?: number
    since?: bigint
    until?: bigint
    content?: InlineMessageContentFilter
  }): Promise<InlineUnreadMessagesResult>
  createChat(params: {
    title: string
    spaceId?: bigint
    description?: string
    emoji?: string
    isPublic?: boolean
    participantUserIds?: bigint[]
  }): Promise<InlineEligibleChat>
  createSubthread(params: {
    parentChatId: bigint
    parentMessageId?: bigint
    title?: string
    description?: string
    emoji?: string
    participantUserIds?: bigint[]
  }): Promise<{ chat: InlineEligibleChat; parentChatId: bigint; parentMessageId: bigint | null; anchorMessageId: bigint | null }>
  forwardMessages(params: {
    sourceChatId: bigint
    destinationChatId: bigint
    messageIds: bigint[]
    shareForwardHeader?: boolean
  }): Promise<InlineForwardMessagesResult>
  uploadFile(params: {
    type: InlineUploadedMediaKind
    file: Uint8Array | ArrayBuffer | SharedArrayBuffer | Blob
    fileName?: string
    contentType?: string
    thumbnail?: Uint8Array | ArrayBuffer | SharedArrayBuffer | Blob
    thumbnailFileName?: string
    thumbnailContentType?: string
    width?: number
    height?: number
    duration?: number
  }): Promise<InlineUploadFileResult>
  sendMessage(params: {
    chatId?: bigint
    userId?: bigint
    text: string
    replyToMsgId?: bigint
    sendMode: "normal" | "silent"
    parseMarkdown: boolean
  }): Promise<{ messageId: bigint | null; spaceId?: bigint | null }>
  sendMediaMessage(params: {
    chatId?: bigint
    userId?: bigint
    media: InlineUploadedMedia
    text?: string
    replyToMsgId?: bigint
    sendMode: "normal" | "silent"
    parseMarkdown: boolean
  }): Promise<{ messageId: bigint | null; spaceId?: bigint | null }>
}

export function createInlineApi(params: {
  baseUrl: string
  token: string
  allowed: InlineAllowedContext
  /** Defaults to the stateless HTTP RPC endpoint. */
  rpc?: InlineRpcInvoker
}): InlineApi {
  // Every supported read and write is one stateless HTTP RPC: no realtime
  // socket, so the server does no connection, presence or sync work for it.
  const rpc = params.rpc ?? createHttpRpcInvoker({ baseUrl: params.baseUrl, token: params.token })
  const invoke = async <K extends RpcInputKind>(method: Method, input: RpcInputOf<K>, options?: InlineRpcCallOptions): Promise<RpcResultOf<K>> =>
    await rpc.invoke(method, input, options) as RpcResultOf<K>

  // Native uploads stream parts over the realtime transfer path, which the
  // HTTP endpoint deliberately does not carry. Only uploadFile opens a socket.
  let uploadClient: { client: InlineSdkClient; connected: Promise<void>; drain: Promise<void> } | null = null
  const uploader = async (): Promise<InlineSdkClient> => {
    if (!uploadClient) {
      const client = new InlineSdkClient({ baseUrl: params.baseUrl, token: params.token, syncUpdates: false })
      // This owner keeps no projection, but must still acknowledge the SDK's
      // bounded update stream so account fanout cannot force a recovery loop.
      const drain = (async () => {
        for await (const _event of client.events()) {
          // Asking for the next event acknowledges the previous receipt.
        }
      })().catch(() => {})
      const entry = { client, connected: client.connect(), drain }
      entry.connected.catch(() => {
        if (uploadClient === entry) uploadClient = null
        void client.close().catch(() => {})
      })
      uploadClient = entry
    }
    const entry = uploadClient
    await entry.connected
    return entry.client
  }
  const allowedSpaceIdList = params.allowed.allowedSpaceIds
  const allowedSpaceIds = new Set(params.allowed.allowedSpaceIds.map((id) => id.toString()))
  type EligibleChatContext = {
    chats: InlineEligibleChat[]
    byChatId: Map<string, InlineEligibleChat>
    senderDisplayNames: Map<string, string>
    senderAvatarUrls: Map<string, string>
  }
  let eligibleChatsCache: (EligibleChatContext & { expiresAtMs: number }) | null = null
  let eligibleChatsInFlight: Promise<EligibleChatContext> | null = null

  const allowDms = params.allowed.allowDms === true
  const allowHomeThreads = params.allowed.allowHomeThreads === true

  const normalizeText = (value: string | null | undefined): string => value?.trim().toLowerCase().replace(/\s+/g, " ") ?? ""

  const userDisplayName = (user: User | null | undefined): string | null => {
    if (!user) return null
    const fullName = [user.firstName?.trim(), user.lastName?.trim()].filter(Boolean).join(" ")
    if (fullName) return fullName
    const username = user.username?.trim()
    if (username) return `@${username}`
    return null
  }

  // Production profile photos use Inline's signed media route. Do not widen
  // the card CSP or pass arbitrary catalog URLs through to the browser.
  const profileAvatarUrl = (value: string | undefined): string | undefined => {
    if (!value || value.length > 4096) return undefined
    try {
      const url = new URL(value)
      if (url.origin !== "https://api.inline.chat" || url.pathname !== "/file" || url.username || url.password || url.hash) return undefined
      if (!["id", "exp", "sig"].every((key) => url.searchParams.get(key))) return undefined
      return url.href
    } catch { return undefined }
  }

  const compareBigIntDesc = (left: bigint | null | undefined, right: bigint | null | undefined): number => {
    const a = left ?? 0n
    const b = right ?? 0n
    if (a === b) return 0
    return a > b ? -1 : 1
  }

  const buildChatPeer = (chatId: bigint) => InputPeer.create({ type: { oneofKind: "chat", chat: { chatId } } })

  /** The SDK sendMessage convenience as one RPC: same validation, idempotency key, receipt and error text. */
  const sendRpcMessage = async (message: {
    target: { kind: "chat"; chatId: bigint } | { kind: "user"; userId: bigint }
    text?: string
    media?: InlineUploadedMedia
    replyToMsgId?: bigint
    silent: boolean
    parseMarkdown?: boolean
  }): Promise<{ messageId: bigint | null }> => {
    const text = message.text
    const hasText = typeof text === "string" && text.length > 0
    if (!hasText && message.media == null) throw new Error("sendMessage: provide `text` and/or `media`")
    if (message.parseMarkdown != null && !hasText) throw new Error("sendMessage: `parseMarkdown` requires non-empty `text`")

    const peerId = message.target.kind === "chat"
      ? buildChatPeer(message.target.chatId)
      : InputPeer.create({ type: { oneofKind: "user", user: { userId: message.target.userId } } })
    const media: InputMedia | undefined = message.media == null
      ? undefined
      : message.media.kind === "photo"
        ? { media: { oneofKind: "photo", photo: { photoId: message.media.id } } }
        : message.media.kind === "video"
          ? { media: { oneofKind: "video", video: { videoId: message.media.id } } }
          : { media: { oneofKind: "document", document: { documentId: message.media.id } } }

    let result: RpcResultOf<"sendMessage">
    try {
      result = await invoke(Method.SEND_MESSAGE, {
        oneofKind: "sendMessage",
        sendMessage: SendMessageInput.create({
          peerId,
          randomId: randomMessageId(),
          ...(hasText ? { message: text } : {}),
          ...(media != null ? { media } : {}),
          ...(message.replyToMsgId != null ? { replyToMsgId: message.replyToMsgId } : {}),
          ...(message.parseMarkdown != null ? { parseMarkdown: message.parseMarkdown } : {}),
          ...(message.silent ? { sendMode: MessageSendMode.MODE_SILENT } : {}),
        }),
      })
    } catch (error) {
      const target = message.target.kind === "chat" ? `chat:${String(message.target.chatId)}` : `user:${String(message.target.userId)}`
      const detail = error instanceof Error ? error.message : String(error)
      throw new Error(
        `sendMessage: request failed (${detail}; target=${target}; media=${message.media?.kind ?? "none"}; textLen=${hasText ? text.length : 0}; replyTo=${message.replyToMsgId != null ? String(message.replyToMsgId) : "none"})`,
        { cause: error as Error },
      )
    }
    return { messageId: firstMessageId(result.sendMessage.updates) }
  }

  const normalizeContentFilter = (content?: InlineMessageContentFilter): InlineMessageContentFilter => {
    if (!content) return "all"
    return content
  }

  const toSearchFilter = (content: InlineMessageContentFilter): SearchMessagesFilter | undefined => {
    switch (content) {
      case "photos":
        return SearchMessagesFilter.FILTER_PHOTOS
      case "videos":
        return SearchMessagesFilter.FILTER_VIDEOS
      case "media":
        return SearchMessagesFilter.FILTER_PHOTO_VIDEO
      case "documents":
      case "files":
        return SearchMessagesFilter.FILTER_DOCUMENTS
      case "links":
        return SearchMessagesFilter.FILTER_LINKS
      default:
        return undefined
    }
  }

  const matchesContentFilter = (message: Message, content: InlineMessageContentFilter): boolean => {
    switch (content) {
      case "links":
        return message.hasLink === true || (message.attachments?.attachments ?? []).some((attachment) => attachment.attachment.oneofKind === "urlPreview")
      case "media":
        return message.media?.media.oneofKind === "photo" || message.media?.media.oneofKind === "video"
      case "photos":
        return message.media?.media.oneofKind === "photo"
      case "videos":
        return message.media?.media.oneofKind === "video"
      case "documents":
      case "files":
        return message.media?.media.oneofKind === "document"
      default:
        return true
    }
  }

  const matchesTimeFilter = (message: Message, since?: bigint, until?: bigint): boolean => {
    if (since != null && message.date < since) return false
    if (until != null && message.date > until) return false
    return true
  }

  const sanitizeParticipantUserIds = (participantUserIds?: bigint[]): bigint[] => {
    const deduped = new Set<string>()
    const out: bigint[] = []
    for (const userId of participantUserIds ?? []) {
      if (userId <= 0n) continue
      const key = userId.toString()
      if (deduped.has(key)) continue
      deduped.add(key)
      out.push(userId)
    }
    return out
  }

  const chatKindOf = (chat: Chat): InlineEligibleChat["kind"] => {
    if (chat.spaceId != null) return "space_chat"
    if (chat.peerId?.type.oneofKind === "user") return "dm"
    return "home_thread"
  }

  const isChatAllowed = (chat: Chat): boolean => {
    const spaceId = chat.spaceId
    if (!spaceId) {
      const peerType = chat.peerId?.type.oneofKind
      if (peerType === "user") return allowDms
      if (peerType === "chat") return allowHomeThreads
      return false
    }
    return allowedSpaceIds.has(spaceId.toString())
  }

  const ensureChatAllowed = (chat: Chat) => {
    if (isChatAllowed(chat)) return
    throw new InlineAccessDeniedError("chat is not in an allowed context")
  }

  // Ordinary (cached) catalog only. Complete archive discovery uses paged GetChats.
  const getChats = async (): Promise<GetChatsResult> => {
    const result = await invoke(Method.GET_CHATS, {
      oneofKind: "getChats",
      getChats: GetChatsInput.create({}),
    })
    return result.getChats
  }

  const getChatResultByPeer = async (peerId: InputPeer) => {
    const result = await invoke(Method.GET_CHAT, { oneofKind: "getChat", getChat: GetChatInput.create({ peerId }) })
    return result.getChat
  }

  const getSpaceMembers = async (spaceId: bigint) => {
    const result = await invoke(Method.GET_SPACE_MEMBERS, {
      oneofKind: "getSpaceMembers",
      getSpaceMembers: GetSpaceMembersInput.create({ spaceId }),
    })
    return result.getSpaceMembers
  }

  const getChatParticipants = async (chatId: bigint) => {
    const result = await invoke(Method.GET_CHAT_PARTICIPANTS, {
      oneofKind: "getChatParticipants",
      getChatParticipants: GetChatParticipantsInput.create({ chatId }),
    })
    return result.getChatParticipants
  }

  const getMessagesByIds = async (chatId: bigint, messageIds: bigint[]): Promise<Message[]> => {
    const result = await invoke(Method.GET_MESSAGES, {
      oneofKind: "getMessages",
      getMessages: GetMessagesInput.create({
        peerId: buildChatPeer(chatId),
        messageIds,
      }),
    })
    return result.getMessages.messages
  }

  const resolveTarget = (params: { chatId?: bigint; userId?: bigint }, context: string): { kind: "chat"; chatId: bigint } | { kind: "user"; userId: bigint } => {
    const hasChatId = params.chatId != null
    const hasUserId = params.userId != null
    if (hasChatId === hasUserId) {
      throw new Error(`${context}: provide exactly one of chatId or userId`)
    }

    if (hasChatId) {
      const chatId = params.chatId
      if (chatId == null || chatId <= 0n) throw new Error(`${context}: invalid chatId`)
      return { kind: "chat", chatId }
    }

    const userId = params.userId
    if (userId == null || userId <= 0n) throw new Error(`${context}: invalid userId`)
    return { kind: "user", userId }
  }

  const resolveUploadMedia = (params: { type: InlineUploadedMediaKind; upload: { photoId?: bigint; videoId?: bigint; documentId?: bigint } }): InlineUploadedMedia => {
    if (params.type === "photo" && params.upload.photoId != null) {
      return { kind: "photo", id: params.upload.photoId }
    }
    if (params.type === "video" && params.upload.videoId != null) {
      return { kind: "video", id: params.upload.videoId }
    }
    if (params.upload.documentId != null) {
      return { kind: "document", id: params.upload.documentId }
    }
    throw new Error(`uploadFile: missing ${params.type} id in upload response`)
  }

  const toEligibleChat = (params: {
    chat: Chat
    dialogByChatId: Map<string, Dialog>
    spaceById: Map<string, Space>
    userById: Map<string, User>
    lastMessageByChatId: Map<string, Pick<Message, "id" | "date">>
  }): InlineEligibleChat => {
    const chat = params.chat
    const peerType = chat.peerId?.type
    const peerUser = peerType?.oneofKind === "user" ? params.userById.get(peerType.user.userId.toString()) ?? null : null
    const peerDisplayName = userDisplayName(peerUser)
    const dialog = params.dialogByChatId.get(chat.id.toString())
    const lastMessage = params.lastMessageByChatId.get(chat.id.toString())
    const title = (peerDisplayName ?? chat.title).trim() || `chat ${chat.id.toString()}`

    return {
      chatId: chat.id,
      title,
      chatTitle: chat.title,
      kind: chatKindOf(chat),
      spaceId: chat.spaceId ?? null,
      spaceName: chat.spaceId != null ? (params.spaceById.get(chat.spaceId.toString())?.name ?? null) : null,
      peerUserId: peerType?.oneofKind === "user" ? peerType.user.userId : null,
      peerDisplayName,
      peerUsername: peerUser?.username?.trim() || null,
      archived: dialog?.archived === true,
      pinned: dialog?.pinned === true,
      unreadCount: dialog?.unreadCount ?? 0,
      readMaxId: dialog?.readMaxId ?? null,
      lastMessageId: lastMessage?.id ?? chat.lastMsgId ?? null,
      lastMessageDate: lastMessage?.date ?? null,
    }
  }

  const toPersonSummary = (params: {
    user: User
    dmChatId?: bigint | null
    spaceIds?: Iterable<bigint>
    spaceNameById?: Map<string, string>
  }): InlinePersonSummary => {
    const user = params.user
    const spaceIds = Array.from(params.spaceIds ?? []).sort((left, right) => (left === right ? 0 : left < right ? -1 : 1))
    return {
      userId: user.id,
      displayName: userDisplayName(user) ?? `user ${user.id.toString()}`,
      username: user.username?.trim() || null,
      firstName: user.firstName?.trim() || null,
      lastName: user.lastName?.trim() || null,
      dmChatId: params.dmChatId ?? null,
      spaceIds,
      spaceNames: spaceIds.map((spaceId) => params.spaceNameById?.get(spaceId.toString()) ?? `space ${spaceId.toString()}`),
    }
  }

  const scorePerson = (person: InlinePersonSummary, normalizedQuery: string): InlinePersonCandidate | null => {
    if (!normalizedQuery) {
      const score = (person.dmChatId != null ? 80 : 0) + person.spaceIds.length * 10
      return {
        ...person,
        score,
        matchReasons: person.dmChatId != null ? ["dm"] : person.spaceIds.length > 0 ? ["space_member"] : [],
      }
    }

    const handleQuery = normalizedQuery.startsWith("@") ? normalizedQuery.slice(1) : normalizedQuery
    const isNumericQuery = /^\d+$/.test(normalizedQuery)
    let score = 0
    const matchReasons: string[] = []

    if (isNumericQuery && person.userId.toString() === normalizedQuery) {
      score += 1_000
      matchReasons.push("user_id_exact")
    } else if (isNumericQuery && person.userId.toString().startsWith(normalizedQuery)) {
      score += 300
      matchReasons.push("user_id_prefix")
    }

    const checkMatch = (value: string | null | undefined, kind: string, exactWeight: number, prefixWeight: number, containsWeight: number) => {
      const normalizedValue = normalizeText(value)
      if (!normalizedValue) return
      if (normalizedValue === normalizedQuery || (kind === "username" && normalizedValue === handleQuery)) {
        score += exactWeight
        matchReasons.push(`${kind}_exact`)
        return
      }
      if (normalizedValue.startsWith(normalizedQuery) || (kind === "username" && normalizedValue.startsWith(handleQuery))) {
        score += prefixWeight
        matchReasons.push(`${kind}_prefix`)
        return
      }
      if (normalizedValue.includes(normalizedQuery) || (kind === "username" && normalizedValue.includes(handleQuery))) {
        score += containsWeight
        matchReasons.push(`${kind}_contains`)
      }
    }

    checkMatch(person.displayName, "name", 700, 420, 220)
    checkMatch(person.username, "username", 800, 460, 260)
    checkMatch(person.firstName, "first_name", 500, 320, 180)
    checkMatch(person.lastName, "last_name", 500, 320, 180)

    if (score <= 0) return null
    if (person.dmChatId != null) {
      score += 50
      matchReasons.push("dm_preference")
    }
    if (person.spaceIds.length > 0) {
      score += Math.min(40, person.spaceIds.length * 10)
      matchReasons.push("shared_space")
    }

    return {
      ...person,
      score,
      matchReasons,
    }
  }

  const comparePeople = (left: InlinePersonCandidate, right: InlinePersonCandidate): number => {
    if (left.score !== right.score) return right.score - left.score
    if ((left.dmChatId != null) !== (right.dmChatId != null)) return left.dmChatId != null ? -1 : 1
    const byName = left.displayName.localeCompare(right.displayName)
    if (byName !== 0) return byName
    return left.userId === right.userId ? 0 : left.userId < right.userId ? -1 : 1
  }

  const buildEligibleChatContext = async (suppliedPayload?: GetChatsResult): Promise<EligibleChatContext> => {
    const payload = suppliedPayload ?? await getChats()
    const dialogByChatId = new Map<string, Dialog>()
    for (const dialog of payload.dialogs) {
      if (dialog.chatId == null) continue
      dialogByChatId.set(dialog.chatId.toString(), dialog)
    }

    const spaceById = new Map<string, Space>()
    for (const space of payload.spaces) {
      spaceById.set(space.id.toString(), space)
    }

    const userById = new Map<string, User>()
    const senderDisplayNames = new Map<string, string>()
    const senderAvatarUrls = new Map<string, string>()
    for (const user of payload.users) {
      userById.set(user.id.toString(), user)
      const name = userDisplayName(user)
      if (name) senderDisplayNames.set(user.id.toString(), name)
      const avatarUrl = profileAvatarUrl(user.profilePhoto?.cdnUrl)
      if (avatarUrl) senderAvatarUrls.set(user.id.toString(), avatarUrl)
    }

    const lastMessageByChatId = new Map<string, Message>()
    for (const message of payload.messages) {
      const key = message.chatId.toString()
      const previous = lastMessageByChatId.get(key)
      if (!previous || message.id > previous.id) {
        lastMessageByChatId.set(key, message)
      }
    }

    const eligible: InlineEligibleChat[] = []
    for (const chat of payload.chats) {
      if (!isChatAllowed(chat)) continue
      eligible.push(toEligibleChat({ chat, dialogByChatId, spaceById, userById, lastMessageByChatId }))
    }

    eligible.sort((a, b) => {
      const byDate = compareBigIntDesc(a.lastMessageDate, b.lastMessageDate)
      if (byDate !== 0) return byDate
      const byLastMessage = compareBigIntDesc(a.lastMessageId, b.lastMessageId)
      if (byLastMessage !== 0) return byLastMessage
      return compareBigIntDesc(a.chatId, b.chatId)
    })

    return {
      chats: eligible,
      byChatId: new Map(eligible.map((chat) => [chat.chatId.toString(), chat])),
      senderDisplayNames,
      senderAvatarUrls,
    }
  }

  // The grant is applied in the server query as kinds plus space_ids, so each
  // page is full and the cursor is the server's. The local check below is
  // defense in depth and never moves the cursor.
  const listChatsPage = async (params: InlineListChatsParams): Promise<InlineListChatsPage> => {
    const { spaceId, kind } = params
    if (spaceId != null && !allowedSpaceIds.has(spaceId.toString())) {
      throw new InlineAccessDeniedError("space is not in allowed context")
    }
    const spaceIds = spaceId != null ? [spaceId] : allowedSpaceIdList
    const kinds: ChatListKind[] = []
    if (spaceIds.length > 0 && (kind == null || kind === "space_chat")) kinds.push(ChatListKind.SPACE_THREAD)
    if (allowDms && spaceId == null && (kind == null || kind === "dm")) kinds.push(ChatListKind.DM)
    if (allowHomeThreads && spaceId == null && (kind == null || kind === "home_thread")) kinds.push(ChatListKind.HOME_THREAD)
    // An empty kind list would mean every kind: the grant leaves nothing to list.
    if (kinds.length === 0) return { chats: [], nextAfterChatId: null }

    const result = await invoke(Method.GET_CHATS, {
      oneofKind: "getChats",
      getChats: GetChatsInput.create({
        limit: params.limit,
        order: ChatListOrder.ID,
        // Archive walks need every accessible chat, with or without a dialog.
        scope: params.includeSubthreads === true ? ChatListScope.ACCESSIBLE : ChatListScope.DIALOGS,
        ...(params.afterChatId != null ? { offset: { chatId: params.afterChatId } } : {}),
        filter: {
          kinds,
          spaceIds: kinds.includes(ChatListKind.SPACE_THREAD) ? spaceIds : [],
          ...(params.unreadOnly === true ? { unread: true } : {}),
        },
      }),
    })
    return {
      chats: eligibleChatsFromPage(result.getChats),
      nextAfterChatId: result.getChats.nextOffset?.chatId ?? null,
    }
  }

  const eligibleChatsFromPage = (payload: GetChatsResult): InlineEligibleChat[] => {
    const dialogByChatId = new Map<string, Dialog>()
    for (const dialog of payload.dialogs) {
      if (dialog.chatId != null) dialogByChatId.set(dialog.chatId.toString(), dialog)
    }
    const spaceById = new Map(payload.spaces.map((space) => [space.id.toString(), space]))
    const userById = new Map(payload.users.map((user) => [user.id.toString(), user]))
    const lastMessageByChatId = new Map(payload.messages.map((message) => [message.chatId.toString(), message]))
    return payload.chats
      .filter(isChatAllowed)
      .map((chat) => toEligibleChat({ chat, dialogByChatId, spaceById, userById, lastMessageByChatId }))
  }

  const getEligibleChatContext = async (refresh = false, suppliedPayload?: GetChatsResult): Promise<EligibleChatContext> => {
    const now = Date.now()
    if (!refresh && eligibleChatsCache && eligibleChatsCache.expiresAtMs > now) {
      return eligibleChatsCache
    }
    if (eligibleChatsInFlight) {
      return await eligibleChatsInFlight
    }

    // Some operations already need a fresh catalog for Spaces or people. On a
    // cold cache, derive the context from that same snapshot instead of issuing
    // another full catalog RPC. Cache hits and in-flight loads retain their TTL.
    eligibleChatsInFlight = buildEligibleChatContext(suppliedPayload)
      .then((context) => {
        eligibleChatsCache = {
          expiresAtMs: Date.now() + 15_000,
          chats: context.chats,
          byChatId: context.byChatId,
          senderDisplayNames: context.senderDisplayNames,
          senderAvatarUrls: context.senderAvatarUrls,
        }
        return context
      })
      .finally(() => {
        eligibleChatsInFlight = null
      })

    return await eligibleChatsInFlight
  }

  // Optional metadata is scoped to this InlineApi, never shared across grants.
  // Legacy sessions can outlive one HTTP request, so bound label reuse to 15s.
  const readUsers = new Map<string, User>()
  const readSpaces = new Map<string, Promise<Space | undefined>>()
  const readLastMessages = new Map<string, Promise<Message | undefined>>()
  let readMetadataExpiresAtMs = 0
  const expireReadMetadata = () => {
    if (readMetadataExpiresAtMs > Date.now()) return
    readUsers.clear()
    readSpaces.clear()
    readLastMessages.clear()
    readMetadataExpiresAtMs = Date.now() + 15_000
  }
  const sendersForMessages = async (messages: Message[], enrich = false) => {
    expireReadMetadata()
    const context = eligibleChatsCache && eligibleChatsCache.expiresAtMs > Date.now() ? eligibleChatsCache : null
    const authorIds = [...new Set(messages.flatMap((message) => message.fromId != null && message.fromId > 0n ? [message.fromId] : []))]
    if (enrich) {
      const missing = authorIds.filter((id) => !readUsers.has(id.toString()) && !context?.senderDisplayNames.has(id.toString()))
      // GET_USERS accepts at most 50 known IDs. Only authors on this authorized
      // returned page are eligible; no roster or global user discovery is needed.
      for (let index = 0; index < missing.length; index += 50) {
        const ids = missing.slice(index, index + 50)
        try {
          const result = await rpc.invoke(Method.GET_USERS, { oneofKind: "getUsers", getUsers: GetUsersInput.create({ userIds: ids }) })
          if (result.oneofKind !== "getUsers") throw new Error("missing users")
          for (const user of result.getUsers.users) {
            if (ids.includes(user.id)) readUsers.set(user.id.toString(), user)
          }
        } catch {
          // Optional public labels must not turn a successful message read into
          // failure (deleted/hidden profiles and rate limits can omit labels).
        }
      }
    }
    const senderDisplayNames: Record<string, string> = {}
    const senderAvatarUrls: Record<string, string> = {}
    for (const id of authorIds) {
      const key = id.toString()
      const user = readUsers.get(key)
      const name = userDisplayName(user ?? null) ?? context?.senderDisplayNames.get(key)
      const avatarUrl = profileAvatarUrl(user?.profilePhoto?.cdnUrl) ?? context?.senderAvatarUrls.get(key)
      if (name) senderDisplayNames[key] = name
      if (avatarUrl) senderAvatarUrls[key] = avatarUrl
    }
    return { senderDisplayNames, senderAvatarUrls }
  }

  const lastMessageForChat = (chatId: bigint, lastMessageId: bigint): Promise<Message | undefined> => {
    expireReadMetadata()
    const key = `${chatId}:${lastMessageId}`
    let pending = readLastMessages.get(key)
    if (!pending) {
      pending = getMessagesByIds(chatId, [lastMessageId])
        .then((messages) => messages.find((message) => message.chatId === chatId && message.id === lastMessageId)).catch(() => undefined)
      readLastMessages.set(key, pending)
    }
    return pending
  }

  const withLatestMessage = async (chat: InlineEligibleChat, messages: Message[], fetchIfMissing = true): Promise<InlineEligibleChat> => {
    const lastMessageId = chat.lastMessageId
    if (lastMessageId == null || lastMessageId <= 0n) return chat
    const fromPage = messages.find((message) => message.chatId === chat.chatId && message.id === lastMessageId)
    if (fromPage) return { ...chat, lastMessageDate: fromPage.date }
    if (chat.lastMessageDate != null || !fetchIfMissing) return chat
    const lastMessage = await lastMessageForChat(chat.chatId, lastMessageId)
    return lastMessage ? { ...chat, lastMessageDate: lastMessage.date } : chat
  }

  const getFreshAllowedChat = async (chatId: bigint, deferLastMessage = false): Promise<{ chat: InlineEligibleChat; result: GetChatResult }> => {
    const result = await getChatResultByPeer(buildChatPeer(chatId))
    const rawChat = result.chat
    if (!rawChat || rawChat.id !== chatId) throw new Error("missing chat")
    ensureChatAllowed(rawChat)
    expireReadMetadata()
    const previous = eligibleChatsCache && eligibleChatsCache.expiresAtMs > Date.now() ? eligibleChatsCache.byChatId.get(chatId.toString()) : undefined
    const peerUserId = rawChat.peerId?.type.oneofKind === "user" ? rawChat.peerId.type.user.userId : null
    const sameContext = previous?.kind === chatKindOf(rawChat) && previous?.spaceId === (rawChat.spaceId ?? null) && previous?.peerUserId === peerUserId
    let spacePromise: Promise<Space | undefined> | undefined
    if (rawChat.spaceId != null && !(sameContext && previous?.spaceName != null)) {
      const key = rawChat.spaceId.toString()
      spacePromise = readSpaces.get(key)
      if (!spacePromise) {
        spacePromise = invoke(Method.GET_SPACE, { oneofKind: "getSpace", getSpace: GetSpaceInput.create({ spaceId: rawChat.spaceId }) })
          .then((response) => response.getSpace.space)
          // Private-chat access does not imply parent-space membership. Labels
          // are optional; GET_CHAT above remains the required authority.
          .catch(() => undefined)
        readSpaces.set(key, spacePromise)
      }
    }
    const lastMessagePromise = !deferLastMessage && rawChat.lastMsgId != null && rawChat.lastMsgId > 0n && !(sameContext && previous?.lastMessageId === rawChat.lastMsgId && previous.lastMessageDate != null)
      ? lastMessageForChat(chatId, rawChat.lastMsgId)
      : undefined
    const [space, lastMessage] = await Promise.all([spacePromise, lastMessagePromise])
    const peerUser = result.user?.id === peerUserId ? result.user : undefined
    if (peerUser) readUsers.set(peerUser.id.toString(), peerUser)
    const chat = toEligibleChat({
      chat: rawChat,
      dialogByChatId: new Map(result.dialog?.chatId === chatId ? [[chatId.toString(), result.dialog]] : []),
      spaceById: new Map(space && space.id === rawChat.spaceId ? [[space.id.toString(), space]] : []),
      userById: new Map(peerUser ? [[peerUser.id.toString(), peerUser]] : []),
      lastMessageByChatId: new Map(lastMessage ? [[chatId.toString(), lastMessage]] : []),
    })
    if (sameContext && previous) {
      chat.spaceName ??= previous.spaceName
      if (!peerUser) {
        chat.peerDisplayName = previous.peerDisplayName
        chat.peerUsername = previous.peerUsername
        chat.title = (previous.peerDisplayName ?? rawChat.title).trim() || `chat ${chatId.toString()}`
      }
      if (previous.lastMessageId === rawChat.lastMsgId) chat.lastMessageDate ??= previous.lastMessageDate
    }
    return { chat, result }
  }

  const getAllowedChat = async (target: { chatId?: bigint; userId?: bigint }, freshChatAuthorization = false, deferLastMessage = false): Promise<InlineEligibleChat> => {
    const resolved = resolveTarget(target, "target")
    if (resolved.kind === "user" && !allowDms) throw new InlineAccessDeniedError("DM access is not allowed for this grant")
    // The legacy user-ID read shape must resolve an existing DM. Backend read
    // RPCs using a user peer can auto-create one, violating readOnlyHint.
    const context = freshChatAuthorization && resolved.kind === "chat"
      ? eligibleChatsCache
      : await getEligibleChatContext(resolved.kind === "user")
    if (resolved.kind === "chat") {
      const fromCache = context?.byChatId.get(resolved.chatId.toString())
      if (fromCache && !freshChatAuthorization) return fromCache
    } else {
      const dmFromCache = context?.chats.find((chat) => chat.kind === "dm" && chat.peerUserId === resolved.userId)
      if (dmFromCache) return dmFromCache
      throw new Error("no existing approved DM conversation found for this user; resolve an existing chat with conversations.list")
    }

    return (await getFreshAllowedChat(resolved.chatId, deferLastMessage)).chat
  }

  const listRecentMessages = async (params: {
    chatId?: bigint
    userId?: bigint
    direction?: "sent" | "all"
    limit?: number
    offsetId?: bigint
    since?: bigint
    until?: bigint
    unreadOnly?: boolean
    content?: InlineMessageContentFilter
    senderUserId?: bigint
    freshChatAuthorization?: boolean
    authorizedChat?: InlineEligibleChat
    enrichSenders?: boolean
  }): Promise<InlineRecentMessagesResult> => {
    const safeDirection: "sent" | "all" = params.direction === "sent" ? "sent" : "all"
    const safeContent = normalizeContentFilter(params.content)
    const safeUnreadOnly = params.unreadOnly === true
    const maxMessages = Math.max(1, Math.min(50, Math.trunc(params.limit ?? 20)))
    const maxScanned = 500

    let chat = params.authorizedChat ?? await getAllowedChat({ chatId: params.chatId, userId: params.userId }, params.freshChatAuthorization ?? true, true)
    const messages: Message[] = []
    let latestMessage: Message | undefined
    let scannedCount = 0
    let nextOffsetId: bigint | null | undefined = params.offsetId

    while (messages.length < maxMessages && scannedCount < maxScanned) {
      const pageLimit = Math.min(50, maxScanned - scannedCount)
      const historyResult = await invoke(Method.GET_CHAT_HISTORY, {
        oneofKind: "getChatHistory",
        getChatHistory: GetChatHistoryInput.create({
          peerId: buildChatPeer(chat.chatId),
          limit: pageLimit,
          ...(nextOffsetId != null ? { offsetId: nextOffsetId } : {}),
        }),
      })

      const historyPage: Message[] = historyResult.getChatHistory.messages
      latestMessage ??= historyPage.find((message) => message.chatId === chat.chatId && message.id === chat.lastMessageId)
      if (historyPage.length === 0) {
        nextOffsetId = null
        break
      }

      let readBoundaryReached = false
      let lastScannedMessage: Message | undefined

      for (const message of historyPage) {
        scannedCount += 1
        lastScannedMessage = message
        if (safeUnreadOnly && chat.readMaxId != null && message.id <= chat.readMaxId) {
          readBoundaryReached = true
          continue
        }
        if (safeDirection === "sent" && !message.out) continue
        if (params.senderUserId != null && message.fromId !== params.senderUserId) continue
        if (!matchesContentFilter(message, safeContent)) continue
        if (!matchesTimeFilter(message, params.since, params.until)) continue

        messages.push(message)
        if (messages.length >= maxMessages) break
      }

      const oldestMessage = lastScannedMessage
      if (!oldestMessage) break
      if (nextOffsetId != null && oldestMessage.id >= nextOffsetId) break
      nextOffsetId = oldestMessage.id

      if (safeUnreadOnly && (readBoundaryReached || (chat.readMaxId != null && oldestMessage.id <= chat.readMaxId))) {
        nextOffsetId = null
        break
      }
      if (params.since != null && oldestMessage.date < params.since) {
        nextOffsetId = null
        break
      }
      if (lastScannedMessage === historyPage[historyPage.length - 1] && historyPage.length < pageLimit) {
        nextOffsetId = null
        break
      }
    }

    chat = await withLatestMessage(chat, latestMessage ? [latestMessage] : [])
    return {
      chat,
      direction: safeDirection,
      scannedCount,
      nextOffsetId: nextOffsetId ?? null,
      messages,
      ...await sendersForMessages(messages, params.enrichSenders !== false),
    }
  }

  const conversationDetails = (chat: InlineEligibleChat, result: GetChatResult, participantResult: Awaited<ReturnType<typeof getChatParticipants>>): InlineConversationDetails => {
    const rawChat = result.chat!
    expireReadMetadata()
    for (const user of participantResult.users) readUsers.set(user.id.toString(), user)
    const participants = participantResult.participants
      .map((participant) => {
        const user = participantResult.users.find((candidate) => candidate.id === participant.userId)
        if (!user) return null
        return toPersonSummary({
          user,
          dmChatId: chat.peerUserId === user.id ? chat.chatId : null,
          spaceIds: rawChat.spaceId != null ? [rawChat.spaceId] : [],
          spaceNameById: rawChat.spaceId != null && chat.spaceName != null ? new Map([[rawChat.spaceId.toString(), chat.spaceName]]) : undefined,
        })
      })
      .filter((person): person is InlinePersonSummary => person != null)

    return {
      chat,
      description: rawChat.description?.trim() || null,
      emoji: rawChat.emoji?.trim() || null,
      isPublic: rawChat.isPublic ?? null,
      date: rawChat.date ?? null,
      createdBy: rawChat.createdBy ?? null,
      parentChatId: rawChat.parentChatId ?? null,
      parentMessageId: rawChat.parentMessageId ?? null,
      number: rawChat.number ?? null,
      pinnedMessageIds: result.pinnedMessageIds ?? [],
      groupParticipantCount: participantResult.groupParticipants.length,
      participants,
    }
  }

  return {
    async close() {
      const entry = uploadClient
      uploadClient = null
      if (!entry) return
      await entry.client.close()
      await entry.drain
    },

    async getProfile() {
      const result = await invoke(Method.GET_ME, { oneofKind: "getMe", getMe: GetMeInput.create({}) })
      const user = result.getMe.user
      if (!user || user.id <= 0n) throw new Error("Authenticated Inline profile is unavailable")
      const name = [user.firstName?.trim(), user.lastName?.trim()].filter(Boolean).join(" ")
      const email = user.email?.trim()
      const nickname = user.username?.trim()
      return {
        id: user.id,
        ...(name ? { name } : {}),
        ...(email ? { email } : {}),
        ...(nickname ? { nickname } : {}),
      }
    },

    async listSpaces({ query, limit }) {
      const payload = await getChats()
      const context = await getEligibleChatContext(false, payload)
      const normalizedQuery = normalizeText(query)
      const maxSpaces = Math.max(1, Math.min(50, Math.trunc(limit ?? 20)))
      const spaceById = new Map(payload.spaces.map((space) => [space.id.toString(), space]))
      const chatsBySpaceId = new Map<string, InlineEligibleChat[]>()
      for (const chat of context.chats) {
        if (chat.spaceId == null) continue
        const key = chat.spaceId.toString()
        const existing = chatsBySpaceId.get(key) ?? []
        existing.push(chat)
        chatsBySpaceId.set(key, existing)
      }

      const items: InlineSpaceSummary[] = []
      for (const spaceId of allowedSpaceIdList) {
        const key = spaceId.toString()
        const space = spaceById.get(key)
        const chats = chatsBySpaceId.get(key) ?? []
        const fallbackName = chats.find((chat) => chat.spaceName)?.spaceName ?? `space ${key}`
        const item: InlineSpaceSummary = {
          id: spaceId,
          name: space?.name?.trim() || fallbackName,
          creator: space?.creator === true,
          date: space?.date ?? null,
          isPublic: space?.isPublic ?? null,
          chatCount: chats.length,
          unreadCount: chats.reduce((sum, chat) => sum + chat.unreadCount, 0),
          lastMessageDate: chats.reduce<bigint | null>((latest, chat) => {
            if (chat.lastMessageDate == null) return latest
            if (latest == null || chat.lastMessageDate > latest) return chat.lastMessageDate
            return latest
          }, null),
        }
        if (normalizedQuery) {
          const normalizedName = normalizeText(item.name)
          if (item.id.toString() !== normalizedQuery && !normalizedName.includes(normalizedQuery)) continue
        }
        items.push(item)
      }

      items.sort((left, right) => {
        const leftDate = left.lastMessageDate ?? 0n
        const rightDate = right.lastMessageDate ?? 0n
        if (leftDate !== rightDate) return leftDate > rightDate ? -1 : 1
        return left.name.localeCompare(right.name)
      })

      return items.slice(0, maxSpaces)
    },

    async searchPeople({ query, limit }) {
      const safeQuery = query?.trim() ?? ""
      const normalizedQuery = normalizeText(safeQuery)
      const maxPeople = Math.max(1, Math.min(50, Math.trunc(limit ?? 20)))
      const payload = await getChats()
      const context = await getEligibleChatContext(false, payload)

      const spaceNameById = new Map<string, string>()
      for (const space of payload.spaces) {
        if (!allowedSpaceIds.has(space.id.toString())) continue
        spaceNameById.set(space.id.toString(), space.name)
      }

      const userById = new Map<string, User>()
      const payloadUserById = new Map<string, User>()
      const spaceIdsByUserId = new Map<string, Set<bigint>>()
      const dmChatIdByUserId = new Map<string, bigint>()

      const addUser = (user: User | null | undefined) => {
        if (!user?.id) return
        userById.set(user.id.toString(), user)
      }
      const addPayloadUserById = (userId: bigint | null | undefined) => {
        if (userId == null) return null
        const user = payloadUserById.get(userId.toString()) ?? null
        addUser(user)
        return user
      }
      const addSpaceUser = (user: User | null | undefined, spaceId: bigint) => {
        addUser(user)
        if (!user?.id) return
        const key = user.id.toString()
        const set = spaceIdsByUserId.get(key) ?? new Set<bigint>()
        set.add(spaceId)
        spaceIdsByUserId.set(key, set)
      }
      const addPayloadSpaceUserById = (userId: bigint | null | undefined, spaceId: bigint) => {
        const user = addPayloadUserById(userId)
        addSpaceUser(user, spaceId)
      }

      for (const user of payload.users) {
        if (!user?.id) continue
        payloadUserById.set(user.id.toString(), user)
      }
      for (const chat of context.chats) {
        if (chat.peerUserId != null) {
          addPayloadUserById(chat.peerUserId)
          if (chat.kind === "dm") dmChatIdByUserId.set(chat.peerUserId.toString(), chat.chatId)
        }
        if (chat.peerUserId != null && chat.spaceId != null) {
          addPayloadSpaceUserById(chat.peerUserId, chat.spaceId)
        }
      }
      for (const message of payload.messages) {
        const chat = context.byChatId.get(message.chatId.toString())
        if (!chat || message.fromId == null) continue
        if (chat.spaceId != null) {
          addPayloadSpaceUserById(message.fromId, chat.spaceId)
        } else {
          addPayloadUserById(message.fromId)
        }
      }

      for (const spaceId of allowedSpaceIdList) {
        const members = await getSpaceMembers(spaceId)
        for (const user of members.users) {
          addSpaceUser(user, spaceId)
        }
      }

      const candidates: InlinePersonCandidate[] = []
      for (const user of userById.values()) {
        const person = toPersonSummary({
          user,
          dmChatId: dmChatIdByUserId.get(user.id.toString()) ?? null,
          spaceIds: spaceIdsByUserId.get(user.id.toString()) ?? [],
          spaceNameById,
        })
        const candidate = scorePerson(person, normalizedQuery)
        if (!candidate) continue
        candidates.push(candidate)
      }

      candidates.sort(comparePeople)
      const items = candidates.slice(0, maxPeople)
      return {
        query: safeQuery || null,
        bestMatch: items[0] ?? null,
        items,
      }
    },

    async getEligibleChats(params) {
      // Archive discovery is opt-in and must not expand the ordinary search
      // and mentions cache. Complete results require the upgraded backing server.
      if (params?.includeSubthreads === true) {
        const chats: InlineEligibleChat[] = []
        let afterChatId: bigint | undefined
        do {
          const page = await listChatsPage({ includeSubthreads: true, limit: 100, ...(afterChatId != null ? { afterChatId } : {}) })
          chats.push(...page.chats)
          if (page.nextAfterChatId != null && afterChatId != null && page.nextAfterChatId <= afterChatId) {
            throw new Error("conversation listing cursor did not advance")
          }
          afterChatId = page.nextAfterChatId ?? undefined
        } while (afterChatId != null)
        return chats.sort((a, b) =>
          compareBigIntDesc(a.lastMessageDate, b.lastMessageDate) ||
          compareBigIntDesc(a.lastMessageId, b.lastMessageId) ||
          compareBigIntDesc(a.chatId, b.chatId))
      }
      const context = await getEligibleChatContext()
      return context.chats
    },

    async listChats(params) {
      return await listChatsPage(params)
    },

    async resolveConversation(query, limit, filters) {
      const normalizedQuery = normalizeText(query)
      if (!normalizedQuery) {
        return {
          query,
          selected: null,
          candidates: [],
        }
      }

      const context = await getEligibleChatContext()
      const handleQuery = normalizedQuery.startsWith("@") ? normalizedQuery.slice(1) : normalizedQuery
      const isNumericQuery = /^\d+$/.test(normalizedQuery)
      const maxCandidates = Math.max(1, Math.min(50, Math.trunc(limit || 1)))
      const candidates: InlineConversationCandidate[] = []

      for (const chat of context.chats) {
        if (filters?.spaceId != null && chat.spaceId !== filters.spaceId) continue
        if (filters?.kind != null && chat.kind !== filters.kind) continue
        if (filters?.unreadOnly && chat.unreadCount === 0) continue
        let score = 0
        const matchReasons: string[] = []
        const chatIdText = chat.chatId.toString()

        if (isNumericQuery && chatIdText === normalizedQuery) {
          score += 1_000
          matchReasons.push("chat_id_exact")
        } else if (isNumericQuery && chatIdText.startsWith(normalizedQuery)) {
          score += 350
          matchReasons.push("chat_id_prefix")
        }

        const checkMatch = (value: string | null | undefined, kind: string, exactWeight: number, prefixWeight: number, containsWeight: number) => {
          const normalizedValue = normalizeText(value)
          if (!normalizedValue) return
          if (normalizedValue === normalizedQuery || (kind === "peer_username" && normalizedValue === handleQuery)) {
            score += exactWeight
            matchReasons.push(`${kind}_exact`)
            return
          }
          if (normalizedValue.startsWith(normalizedQuery)) {
            score += prefixWeight
            matchReasons.push(`${kind}_prefix`)
            return
          }
          if (normalizedValue.includes(normalizedQuery)) {
            score += containsWeight
            matchReasons.push(`${kind}_contains`)
          }
        }

        checkMatch(chat.peerDisplayName, "peer_name", 360, 230, 130)
        checkMatch(chat.peerUsername, "peer_username", 400, 240, 150)
        checkMatch(chat.title, "title", 280, 190, 120)
        checkMatch(chat.chatTitle, "chat_title", 220, 150, 100)

        if (score <= 0) continue
        if (chat.kind === "dm") {
          score += 40
          matchReasons.push("dm_preference")
        }
        if (chat.archived) {
          score -= 30
          matchReasons.push("archived_penalty")
        }
        if (chat.pinned) {
          score += 10
          matchReasons.push("pinned_bonus")
        }

        candidates.push({
          ...chat,
          score,
          matchReasons,
        })
      }

      candidates.sort((a, b) => {
        if (filters?.sort === "unread" && a.unreadCount !== b.unreadCount) return b.unreadCount - a.unreadCount
        if (filters?.sort === "recent" || filters?.sort === "unread") {
          const byDate = compareBigIntDesc(a.lastMessageDate, b.lastMessageDate)
          if (byDate !== 0) return byDate
          return compareBigIntDesc(a.chatId, b.chatId)
        }
        if (a.score !== b.score) return b.score - a.score
        if (a.kind !== b.kind) {
          if (a.kind === "dm") return -1
          if (b.kind === "dm") return 1
        }
        const byLastMessageDate = compareBigIntDesc(a.lastMessageDate, b.lastMessageDate)
        if (byLastMessageDate !== 0) return byLastMessageDate
        return compareBigIntDesc(a.chatId, b.chatId)
      })

      const top = candidates.slice(0, maxCandidates)
      return {
        query,
        selected: top[0] ?? null,
        candidates: top,
      }
    },

    async getConversation({ chatId, userId }) {
      const target = resolveTarget({ chatId, userId }, "target")
      // User IDs still require existing-DM discovery; canonical IDs go directly
      // through fresh GET_CHAT authorization and reuse its complete result.
      const canonicalChatId = target.kind === "chat" ? target.chatId : (await getAllowedChat({ userId: target.userId })).chatId
      const { chat, result } = await getFreshAllowedChat(canonicalChatId)
      return conversationDetails(chat, result, await getChatParticipants(chat.chatId))
    },

    async openConversation({ chatId, limit }) {
      resolveTarget({ chatId }, "target")
      // This target is shared only within this single logical read. Subsequent
      // tools still execute fresh GET_CHAT; no completed authorization is cached.
      const { chat, result } = await getFreshAllowedChat(chatId, true)
      const [participants, recent] = await Promise.allSettled([
        getChatParticipants(chat.chatId),
        listRecentMessages({ chatId: chat.chatId, authorizedChat: chat, limit: limit ?? 50, enrichSenders: false }),
      ])
      // Drain both authorized readers before returning an error. Match the
      // original details-first failure precedence without orphaned work.
      if (participants.status === "rejected") throw participants.reason
      if (recent.status === "rejected") throw recent.reason
      const details = conversationDetails(recent.value.chat, result, participants.value)
      const history = { ...recent.value, ...await sendersForMessages(recent.value.messages, true) }
      return { details, history }
    },

    async messageContext({ chatId, userId, anchorMessageId, before, after, includeAnchor, content }) {
      const safeBefore = Math.max(0, Math.min(50, Math.trunc(before ?? 8)))
      const safeAfter = Math.max(0, Math.min(50, Math.trunc(after ?? 8)))
      const safeIncludeAnchor = includeAnchor !== false
      const safeContent = normalizeContentFilter(content)
      const chat = await getAllowedChat({ chatId, userId }, true, true)

      if (anchorMessageId != null) {
        const result = await invoke(Method.GET_CHAT_HISTORY, {
          oneofKind: "getChatHistory",
          getChatHistory: GetChatHistoryInput.create({
            peerId: buildChatPeer(chat.chatId),
            mode: GetChatHistoryMode.HISTORY_MODE_AROUND,
            anchorId: anchorMessageId,
            beforeLimit: safeBefore,
            afterLimit: safeAfter,
            includeAnchor: safeIncludeAnchor,
          }),
        })
        return {
          chat: await withLatestMessage(chat, result.getChatHistory.messages),
          anchorMessageId,
          before: safeBefore,
          after: safeAfter,
          includeAnchor: safeIncludeAnchor,
          content: safeContent,
          messages: result.getChatHistory.messages.filter((message) => matchesContentFilter(message, safeContent)),
        }
      }

      const recent = await listRecentMessages({
        chatId: chat.chatId,
        authorizedChat: chat,
        enrichSenders: false,
        limit: Math.max(1, safeBefore + safeAfter + (safeIncludeAnchor ? 1 : 0)),
        content: safeContent,
      })
      return {
        chat: recent.chat,
        anchorMessageId: recent.messages[0]?.id ?? null,
        before: safeBefore,
        after: safeAfter,
        includeAnchor: safeIncludeAnchor,
        content: safeContent,
        messages: recent.messages,
      }
    },

    async getMessages({ chatId, userId, messageIds }) {
      const chat = await getAllowedChat({ chatId, userId }, true, true)
      const uniqueIds: bigint[] = []
      const seen = new Set<string>()
      for (const messageId of messageIds) {
        if (messageId <= 0n) throw new Error("invalid messageId")
        const key = messageId.toString()
        if (seen.has(key)) continue
        seen.add(key)
        uniqueIds.push(messageId)
      }
      const lastMessageId = chat.lastMessageId
      const queryIds = [...uniqueIds]
      // The backend accepts at most 1000 IDs. Piggyback optional last-message
      // metadata without expanding an already-full requested batch.
      if (chat.lastMessageDate == null && lastMessageId != null && lastMessageId > 0n && !seen.has(lastMessageId.toString()) && queryIds.length < 1_000) queryIds.push(lastMessageId)
      const messages = await getMessagesByIds(chat.chatId, queryIds)
      const byId = new Map(messages.filter((message) => message.chatId === chat.chatId).map((message) => [message.id.toString(), message]))
      return {
        chat: await withLatestMessage(chat, messages, lastMessageId == null || !queryIds.includes(lastMessageId)),
        // A metadata-only row never escapes the caller's exact selection. Keep
        // the original unique requested order even when the backend omits IDs.
        messages: uniqueIds.flatMap((id) => byId.get(id.toString()) ?? []),
      }
    },

    async recentMessages(params) {
      return await listRecentMessages(params)
    },

    async searchMessages({ chatId, userId, query, limit, offsetId, senderUserId, since, until, content }) {
      const safeQuery = query?.trim()
      const safeContent = normalizeContentFilter(content)
      const maxMessages = Math.max(1, Math.min(50, Math.trunc(limit ?? 20)))

      if (!safeQuery) {
        const fallback = await listRecentMessages({
          chatId,
          userId,
          direction: "all",
          limit: maxMessages,
          offsetId,
          senderUserId,
          since,
          until,
          content: safeContent,
        })
        return {
          chat: fallback.chat,
          query: null,
          content: safeContent,
          mode: "scan",
          scannedCount: fallback.scannedCount,
          nextOffsetId: fallback.nextOffsetId,
          messages: fallback.messages,
          senderDisplayNames: fallback.senderDisplayNames,
          senderAvatarUrls: fallback.senderAvatarUrls,
        }
      }

      const chat = await getAllowedChat({ chatId, userId }, true, true)
      const peerId = buildChatPeer(chat.chatId)

      const result = await invoke(Method.SEARCH_MESSAGES, {
        oneofKind: "searchMessages",
        searchMessages: SearchMessagesInput.create({
          peerId,
          queries: [safeQuery],
          limit: maxMessages,
          ...(offsetId != null ? { offsetId } : {}),
          ...(toSearchFilter(safeContent) != null ? { filter: toSearchFilter(safeContent) } : {}),
        }),
      })
      const sourceMessages = result.searchMessages.messages
      const messages = sourceMessages
        .filter((message) => senderUserId == null || message.fromId === senderUserId)
        .filter((message) => matchesTimeFilter(message, since, until))
        .filter((message) => matchesContentFilter(message, safeContent))

      return {
        chat: await withLatestMessage(chat, sourceMessages),
        query: safeQuery,
        content: safeContent,
        mode: "search",
        scannedCount: sourceMessages.length,
        nextOffsetId: sourceMessages.length >= maxMessages ? sourceMessages[sourceMessages.length - 1]!.id : null,
        messages,
        ...await sendersForMessages(messages, true),
      }
    },

    async unreadMessages({ limit, since, until, content }) {
      const maxMessages = Math.max(1, Math.min(200, Math.trunc(limit ?? 50)))
      const safeContent = normalizeContentFilter(content)
      const context = await getEligibleChatContext()
      const unreadChats = context.chats.filter((chat) => chat.unreadCount > 0)

      const items: Array<{ chat: InlineEligibleChat; message: Message }> = []
      let scannedChats = 0
      for (const chat of unreadChats) {
        if (items.length >= maxMessages) break
        scannedChats += 1

        const remaining = maxMessages - items.length
        const result = await listRecentMessages({
          chatId: chat.chatId,
          direction: "all",
          limit: Math.min(50, Math.max(remaining, chat.unreadCount)),
          since,
          until,
          unreadOnly: true,
          content: safeContent,
          freshChatAuthorization: false,
          enrichSenders: false,
        })
        for (const message of result.messages) {
          items.push({ chat: result.chat, message })
          if (items.length >= maxMessages) break
        }
      }

      items.sort((a, b) => compareBigIntDesc(a.message.date, b.message.date))
      return {
        scannedChats,
        items,
      }
    },

    async createChat({ title, spaceId, description, emoji, isPublic, participantUserIds }) {
      const safeTitle = title.trim()
      if (!safeTitle) throw new Error("title is required")
      if (spaceId != null && !allowedSpaceIds.has(spaceId.toString())) {
        throw new InlineAccessDeniedError("space is not in allowed context")
      }
      if (spaceId == null && !allowHomeThreads) {
        throw new InlineAccessDeniedError("home thread creation is not allowed for this grant")
      }

      const participants = sanitizeParticipantUserIds(participantUserIds).map((userId) => InputChatParticipant.create({ userId }))
      const result = await invoke(Method.CREATE_CHAT, {
        oneofKind: "createChat",
        createChat: CreateChatInput.create({
          title: safeTitle,
          ...(spaceId != null ? { spaceId } : {}),
          ...(description?.trim() ? { description: description.trim() } : {}),
          ...(emoji?.trim() ? { emoji: emoji.trim() } : {}),
          isPublic: isPublic === true,
          participants,
        }),
      })
      const createdChat = result.createChat.chat
      if (!createdChat) throw new Error("createChat returned no chat")

      eligibleChatsCache = null
      // CREATE_CHAT is the write receipt. Optional catalog enrichment must not
      // turn a confirmed creation into an ambiguous failure and invite a retry.
      // Subsequent reads/sends still perform their ordinary authorization.
      return toEligibleChat({
        chat: createdChat,
        dialogByChatId: new Map(),
        spaceById: new Map(),
        userById: new Map(),
        lastMessageByChatId: new Map(),
      })
    },

    async createSubthread({ parentChatId, parentMessageId, title, description, emoji, participantUserIds }) {
      const parent = await getAllowedChat({ chatId: parentChatId })
      // A child of a DM is a home thread. Do not create it and discover only
      // afterward that the grant cannot inspect or send to the result.
      if (parent.spaceId == null && !allowHomeThreads) {
        throw new Error("subthread creation outside spaces requires home thread access for this grant")
      }
      const result = await rpc.invoke(Method.CREATE_SUBTHREAD, {
        oneofKind: "createSubthread",
        createSubthread: CreateSubthreadInput.create({
          parentChatId,
          ...(parentMessageId != null ? { parentMessageId } : {}),
          ...(title?.trim() ? { title: title.trim() } : {}),
          ...(description?.trim() ? { description: description.trim() } : {}),
          ...(emoji?.trim() ? { emoji: emoji.trim() } : {}),
          participants: sanitizeParticipantUserIds(participantUserIds).map((userId) => InputChatParticipant.create({ userId })),
        }),
      })
      if (result.oneofKind !== "createSubthread" || !result.createSubthread.chat) {
        throw new Error("createSubthread returned no chat; inspect the parent before retrying because the child may have been created")
      }
      eligibleChatsCache = null
      // The RPC already confirms the child. Later reads still authorize it,
      // but their failure must not discard this creation receipt.
      return {
        chat: toEligibleChat({
          chat: result.createSubthread.chat,
          dialogByChatId: new Map(),
          spaceById: new Map(),
          userById: new Map(),
          lastMessageByChatId: new Map(),
        }),
        parentChatId,
        parentMessageId: parentMessageId ?? null,
        anchorMessageId: result.createSubthread.anchorMessage?.id ?? null,
      }
    },

    async forwardMessages({ sourceChatId, destinationChatId, messageIds, shareForwardHeader }) {
      const sourceChat = await getAllowedChat({ chatId: sourceChatId })
      const destinationChat = await getAllowedChat({ chatId: destinationChatId })
      if (messageIds.length === 0 || messageIds.length > 100 || messageIds.some((id) => id <= 0n)) {
        throw new Error("forwardMessages requires one to one hundred positive message IDs")
      }
      try {
        const result = await invoke(Method.FORWARD_MESSAGES, {
          oneofKind: "forwardMessages",
          forwardMessages: ForwardMessagesInput.create({
            fromPeerId: buildChatPeer(sourceChatId),
            toPeerId: buildChatPeer(destinationChatId),
            messageIds,
            shareForwardHeader: shareForwardHeader !== false,
          }),
        })
        // The RPC contains ordered send updates, not a source/destination map.
        // Its one receipt per source input is the server's send contract.
        const destinationIds = result.forwardMessages.updates.flatMap(({ update }) =>
          update.oneofKind === "updateMessageId" ? [update.updateMessageId.messageId] : [],
        )
        if (destinationIds.length !== messageIds.length || destinationIds.some((id) => id <= 0n)) {
          throw new Error("forwardMessages returned incomplete delivery receipts")
        }
        return {
          sourceChat,
          destinationChat,
          messages: messageIds.map((sourceMessageId, index) => ({ sourceMessageId, destinationMessageId: destinationIds[index]! })),
        }
      } catch (error) {
        const detail = error instanceof Error ? error.message : String(error)
        throw new Error(`Forwarding failed: ${detail}. Some messages may already have been delivered. Inspect the destination before retrying; retrying can create duplicates.`)
      }
    },

    async uploadFile({ type, file, fileName, contentType, thumbnail, thumbnailFileName, thumbnailContentType, width, height, duration }) {
      const client = await uploader()
      const upload = await client.uploadFile({
        type,
        file,
        ...(fileName ? { fileName } : {}),
        ...(contentType ? { contentType } : {}),
        ...(thumbnail != null ? { thumbnail } : {}),
        ...(thumbnailFileName ? { thumbnailFileName } : {}),
        ...(thumbnailContentType ? { thumbnailContentType } : {}),
        ...(width != null ? { width } : {}),
        ...(height != null ? { height } : {}),
        ...(duration != null ? { duration } : {}),
      })
      return {
        fileUniqueId: upload.fileUniqueId,
        media: resolveUploadMedia({
          type,
          upload,
        }),
      }
    },

    async sendMessage({ chatId, userId, text, replyToMsgId, sendMode, parseMarkdown }) {
      const target = resolveTarget({ chatId, userId }, "sendMessage")
      if (target.kind === "user" && !allowDms) {
        throw new InlineAccessDeniedError("DM access is not allowed for this grant")
      }

      const chat = target.kind === "chat" ? await getAllowedChat({ chatId: target.chatId }) : null

      const res = await sendRpcMessage({
        target,
        text,
        ...(replyToMsgId != null ? { replyToMsgId } : {}),
        silent: sendMode === "silent",
        parseMarkdown,
      })
      return { messageId: res.messageId, spaceId: chat?.spaceId ?? null }
    },

    async sendMediaMessage({ chatId, userId, media, text, replyToMsgId, sendMode, parseMarkdown }) {
      const target = resolveTarget({ chatId, userId }, "sendMediaMessage")
      if (target.kind === "user" && !allowDms) {
        throw new InlineAccessDeniedError("DM access is not allowed for this grant")
      }

      const chat = target.kind === "chat" ? await getAllowedChat({ chatId: target.chatId }) : null
      const caption = text?.trim() ? text : undefined

      const res = await sendRpcMessage({
        target,
        ...(caption ? { text: caption } : {}),
        media,
        ...(replyToMsgId != null ? { replyToMsgId } : {}),
        silent: sendMode === "silent",
        ...(caption ? { parseMarkdown } : {}),
      })
      return { messageId: res.messageId, spaceId: chat?.spaceId ?? null }
    },

  }
}
