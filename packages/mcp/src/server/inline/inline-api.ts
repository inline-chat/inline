import { InlineSdkClient } from "@inline-chat/realtime-sdk"
import {
  CreateChatInput,
  GetChatHistoryMode,
  GetChatHistoryInput,
  GetChatParticipantsInput,
  GetChatsInput,
  GetChatInput,
  GetMessagesInput,
  GetSpaceMembersInput,
  InputChatParticipant,
  InputPeer,
  Method,
  SearchMessagesInput,
  SearchMessagesFilter,
  type Chat,
  type Dialog,
  type GetChatsResult,
  type Message,
  type Space,
  type User,
} from "@inline-chat/protocol/core"

export type InlineAllowedContext = {
  allowedSpaceIds: bigint[]
  allowDms?: boolean
  allowHomeThreads?: boolean
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

export type InlineConversationCandidate = InlineEligibleChat & {
  score: number
  matchReasons: string[]
}

export type InlineConversationResolution = {
  query: string
  selected: InlineConversationCandidate | null
  candidates: InlineConversationCandidate[]
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
}

export type InlineSearchMessagesResult = {
  chat: InlineEligibleChat
  query: string | null
  content: InlineMessageContentFilter
  mode: "search" | "scan"
  messages: Message[]
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
  listSpaces(params: { query?: string; limit?: number }): Promise<InlineSpaceSummary[]>
  searchPeople(params: { query?: string; limit?: number }): Promise<{ query: string | null; bestMatch: InlinePersonCandidate | null; items: InlinePersonCandidate[] }>
  getEligibleChats(): Promise<InlineEligibleChat[]>
  resolveConversation(query: string, limit: number): Promise<InlineConversationResolution>
  getConversation(params: { chatId?: bigint; userId?: bigint }): Promise<InlineConversationDetails>
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
  }): Promise<InlineRecentMessagesResult>
  searchMessages(params: {
    chatId?: bigint
    userId?: bigint
    query?: string
    limit?: number
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
}): InlineApi {
  const client = new InlineSdkClient({ baseUrl: params.baseUrl, token: params.token })
  const allowedSpaceIdList = params.allowed.allowedSpaceIds
  const allowedSpaceIds = new Set(params.allowed.allowedSpaceIds.map((id) => id.toString()))
  let connected: Promise<void> | null = null
  let eligibleChatsCache:
    | {
        expiresAtMs: number
        chats: InlineEligibleChat[]
        byChatId: Map<string, InlineEligibleChat>
      }
    | null = null
  let eligibleChatsInFlight: Promise<{
    chats: InlineEligibleChat[]
    byChatId: Map<string, InlineEligibleChat>
  }> | null = null

  const ensureConnected = async () => {
    if (!connected) {
      connected = client.connect().catch((e) => {
        connected = null
        throw e
      })
    }
    await connected
  }

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

  const compareBigIntDesc = (left: bigint | null | undefined, right: bigint | null | undefined): number => {
    const a = left ?? 0n
    const b = right ?? 0n
    if (a === b) return 0
    return a > b ? -1 : 1
  }

  const buildChatPeer = (chatId: bigint) => InputPeer.create({ type: { oneofKind: "chat", chat: { chatId } } })
  const buildUserPeer = (userId: bigint) => InputPeer.create({ type: { oneofKind: "user", user: { userId } } })

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
    throw new Error("chat is not in an allowed context")
  }

  const getChats = async (): Promise<GetChatsResult> => {
    await ensureConnected()
    const result = await client.invoke(Method.GET_CHATS, { oneofKind: "getChats", getChats: GetChatsInput.create({}) })
    return result.getChats
  }

  const getChatById = async (chatId: bigint): Promise<Chat> => {
    await ensureConnected()
    const result = await client.invoke(Method.GET_CHAT, { oneofKind: "getChat", getChat: GetChatInput.create({ peerId: buildChatPeer(chatId) }) })
    const chat = result.getChat.chat
    if (!chat) throw new Error("missing chat")
    return chat
  }

  const getChatResultByPeer = async (peerId: InputPeer) => {
    await ensureConnected()
    const result = await client.invoke(Method.GET_CHAT, { oneofKind: "getChat", getChat: GetChatInput.create({ peerId }) })
    return result.getChat
  }

  const getChatByUserId = async (userId: bigint): Promise<Chat> => {
    await ensureConnected()
    const result = await client.invoke(Method.GET_CHAT, { oneofKind: "getChat", getChat: GetChatInput.create({ peerId: buildUserPeer(userId) }) })
    const chat = result.getChat.chat
    if (!chat) throw new Error("missing chat")
    return chat
  }

  const getSpaceMembers = async (spaceId: bigint) => {
    await ensureConnected()
    const result = await client.invoke(Method.GET_SPACE_MEMBERS, {
      oneofKind: "getSpaceMembers",
      getSpaceMembers: GetSpaceMembersInput.create({ spaceId }),
    })
    return result.getSpaceMembers
  }

  const getChatParticipants = async (chatId: bigint) => {
    await ensureConnected()
    const result = await client.invoke(Method.GET_CHAT_PARTICIPANTS, {
      oneofKind: "getChatParticipants",
      getChatParticipants: GetChatParticipantsInput.create({ chatId }),
    })
    return result.getChatParticipants
  }

  const getMessagesByIds = async (chatId: bigint, messageIds: bigint[]): Promise<Message[]> => {
    await ensureConnected()
    const result = await client.invoke(Method.GET_MESSAGES, {
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
    lastMessageByChatId: Map<string, Message>
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

  const buildEligibleChatContext = async (): Promise<{
    chats: InlineEligibleChat[]
    byChatId: Map<string, InlineEligibleChat>
  }> => {
    const payload = await getChats()
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
    for (const user of payload.users) {
      userById.set(user.id.toString(), user)
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
    }
  }

  const getEligibleChatContext = async (): Promise<{
    chats: InlineEligibleChat[]
    byChatId: Map<string, InlineEligibleChat>
  }> => {
    const now = Date.now()
    if (eligibleChatsCache && eligibleChatsCache.expiresAtMs > now) {
      return eligibleChatsCache
    }
    if (eligibleChatsInFlight) {
      return await eligibleChatsInFlight
    }

    eligibleChatsInFlight = buildEligibleChatContext()
      .then((context) => {
        eligibleChatsCache = {
          expiresAtMs: Date.now() + 15_000,
          chats: context.chats,
          byChatId: context.byChatId,
        }
        return context
      })
      .finally(() => {
        eligibleChatsInFlight = null
      })

    return await eligibleChatsInFlight
  }

  const getAllowedChat = async (target: { chatId?: bigint; userId?: bigint }): Promise<InlineEligibleChat> => {
    const resolved = resolveTarget(target, "target")
    const context = await getEligibleChatContext()
    if (resolved.kind === "chat") {
      const fromCache = context.byChatId.get(resolved.chatId.toString())
      if (fromCache) return fromCache
    } else {
      const dmFromCache = context.chats.find((chat) => chat.peerUserId === resolved.userId)
      if (dmFromCache) return dmFromCache
      if (!allowDms) {
        throw new Error("DM access is not allowed for this grant")
      }
    }

    const chat = resolved.kind === "chat" ? await getChatById(resolved.chatId) : await getChatByUserId(resolved.userId)
    ensureChatAllowed(chat)
    return {
      chatId: chat.id,
      title: chat.title.trim() || `chat ${chat.id.toString()}`,
      chatTitle: chat.title,
      kind: chatKindOf(chat),
      spaceId: chat.spaceId ?? null,
      spaceName: null,
      peerUserId: chat.peerId?.type.oneofKind === "user" ? chat.peerId.type.user.userId : null,
      peerDisplayName: null,
      peerUsername: null,
      archived: false,
      pinned: false,
      unreadCount: 0,
      readMaxId: null,
      lastMessageId: chat.lastMsgId ?? null,
      lastMessageDate: null,
    }
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
  }): Promise<InlineRecentMessagesResult> => {
    const safeDirection: "sent" | "all" = params.direction === "sent" ? "sent" : "all"
    const safeContent = normalizeContentFilter(params.content)
    const safeUnreadOnly = params.unreadOnly === true
    const maxMessages = Math.max(1, Math.min(50, Math.trunc(params.limit ?? 20)))
    const maxScanned = 500

    const chat = await getAllowedChat({ chatId: params.chatId, userId: params.userId })
    const messages: Message[] = []
    let scannedCount = 0
    let nextOffsetId: bigint | null | undefined = params.offsetId

    while (messages.length < maxMessages && scannedCount < maxScanned) {
      await ensureConnected()
      const pageLimit = Math.min(50, maxScanned - scannedCount)
      const historyResult = await client.invoke(Method.GET_CHAT_HISTORY, {
        oneofKind: "getChatHistory",
        getChatHistory: GetChatHistoryInput.create({
          peerId: buildChatPeer(chat.chatId),
          limit: pageLimit,
          ...(nextOffsetId != null ? { offsetId: nextOffsetId } : {}),
        }),
      })

      const historyPage: Message[] = historyResult.getChatHistory.messages
      if (historyPage.length === 0) {
        nextOffsetId = null
        break
      }

      scannedCount += historyPage.length
      let readBoundaryReached = false

      for (const message of historyPage) {
        if (safeUnreadOnly && chat.readMaxId != null && message.id <= chat.readMaxId) {
          readBoundaryReached = true
          continue
        }
        if (safeDirection === "sent" && !message.out) continue
        if (!matchesContentFilter(message, safeContent)) continue
        if (!matchesTimeFilter(message, params.since, params.until)) continue

        messages.push(message)
        if (messages.length >= maxMessages) break
      }

      const oldestMessage = historyPage[historyPage.length - 1]
      if (!oldestMessage) break
      if (nextOffsetId != null && oldestMessage.id >= nextOffsetId) break
      nextOffsetId = oldestMessage.id

      if (safeUnreadOnly && (readBoundaryReached || (chat.readMaxId != null && oldestMessage.id <= chat.readMaxId))) break
      if (params.since != null && oldestMessage.date < params.since) break
      if (historyPage.length < pageLimit) break
    }

    return {
      chat,
      direction: safeDirection,
      scannedCount,
      nextOffsetId: nextOffsetId ?? null,
      messages,
    }
  }

  return {
    async close() {
      await client.close()
    },

    async listSpaces({ query, limit }) {
      const payload = await getChats()
      const context = await getEligibleChatContext()
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
      const [payload, context] = await Promise.all([getChats(), getEligibleChatContext()])

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

    async getEligibleChats() {
      const context = await getEligibleChatContext()
      return context.chats
    },

    async resolveConversation(query, limit) {
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
      const maxCandidates = Math.max(1, Math.min(20, Math.trunc(limit || 1)))
      const candidates: InlineConversationCandidate[] = []

      for (const chat of context.chats) {
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
      const target = resolveTarget({ chatId, userId }, "getConversation")
      if (target.kind === "user" && !allowDms) {
        throw new Error("DM access is not allowed for this grant")
      }
      const peerId = target.kind === "chat" ? buildChatPeer(target.chatId) : buildUserPeer(target.userId)
      const result = await getChatResultByPeer(peerId)
      const rawChat = result.chat
      if (!rawChat) throw new Error("missing chat")
      ensureChatAllowed(rawChat)

      const context = await getEligibleChatContext()
      const chat = context.byChatId.get(rawChat.id.toString()) ?? (await getAllowedChat({ chatId: rawChat.id }))
      const participantResult = await getChatParticipants(rawChat.id)
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
        groupParticipantCount: 0,
        participants,
      }
    },

    async messageContext({ chatId, userId, anchorMessageId, before, after, includeAnchor, content }) {
      const safeBefore = Math.max(0, Math.min(50, Math.trunc(before ?? 8)))
      const safeAfter = Math.max(0, Math.min(50, Math.trunc(after ?? 8)))
      const safeIncludeAnchor = includeAnchor !== false
      const safeContent = normalizeContentFilter(content)
      const chat = await getAllowedChat({ chatId, userId })

      if (anchorMessageId != null) {
        await ensureConnected()
        const result = await client.invoke(Method.GET_CHAT_HISTORY, {
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
          chat,
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
        limit: Math.max(1, safeBefore + safeAfter + (safeIncludeAnchor ? 1 : 0)),
        content: safeContent,
      })
      return {
        chat,
        anchorMessageId: recent.messages[0]?.id ?? null,
        before: safeBefore,
        after: safeAfter,
        includeAnchor: safeIncludeAnchor,
        content: safeContent,
        messages: recent.messages,
      }
    },

    async getMessages({ chatId, userId, messageIds }) {
      const chat = await getAllowedChat({ chatId, userId })
      const uniqueIds: bigint[] = []
      const seen = new Set<string>()
      for (const messageId of messageIds) {
        if (messageId <= 0n) throw new Error("invalid messageId")
        const key = messageId.toString()
        if (seen.has(key)) continue
        seen.add(key)
        uniqueIds.push(messageId)
      }
      return {
        chat,
        messages: await getMessagesByIds(chat.chatId, uniqueIds),
      }
    },

    async recentMessages(params) {
      return await listRecentMessages(params)
    },

    async searchMessages({ chatId, userId, query, limit, since, until, content }) {
      const safeQuery = query?.trim()
      const safeContent = normalizeContentFilter(content)
      const maxMessages = Math.max(1, Math.min(50, Math.trunc(limit ?? 20)))

      if (!safeQuery) {
        const fallback = await listRecentMessages({
          chatId,
          userId,
          direction: "all",
          limit: maxMessages,
          since,
          until,
          content: safeContent,
        })
        return {
          chat: fallback.chat,
          query: null,
          content: safeContent,
          mode: "scan",
          messages: fallback.messages,
        }
      }

      const target = resolveTarget({ chatId, userId }, "searchMessages")
      const chat = await getAllowedChat({ chatId, userId })
      const peerId = target.kind === "chat" ? buildChatPeer(target.chatId) : buildUserPeer(target.userId)

      await ensureConnected()
      const result = await client.invoke(Method.SEARCH_MESSAGES, {
        oneofKind: "searchMessages",
        searchMessages: SearchMessagesInput.create({
          peerId,
          queries: [safeQuery],
          limit: maxMessages,
          ...(toSearchFilter(safeContent) != null ? { filter: toSearchFilter(safeContent) } : {}),
        }),
      })
      const messages = result.searchMessages.messages.filter((message) => matchesTimeFilter(message, since, until)).filter((message) => matchesContentFilter(message, safeContent))

      return {
        chat,
        query: safeQuery,
        content: safeContent,
        mode: "search",
        messages,
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
        throw new Error("space is not in allowed context")
      }
      if (spaceId == null && !allowHomeThreads) {
        throw new Error("home thread creation is not allowed for this grant")
      }

      const participants = sanitizeParticipantUserIds(participantUserIds).map((userId) => InputChatParticipant.create({ userId }))
      await ensureConnected()
      const result = await client.invoke(Method.CREATE_CHAT, {
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
      return await getAllowedChat({ chatId: createdChat.id })
    },

    async uploadFile({ type, file, fileName, contentType, thumbnail, thumbnailFileName, thumbnailContentType, width, height, duration }) {
      await ensureConnected()
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
        throw new Error("DM access is not allowed for this grant")
      }

      const chat = target.kind === "chat" ? await getAllowedChat({ chatId: target.chatId }) : null

      await ensureConnected()
      const res = await client.sendMessage({
        ...(target.kind === "chat" ? { chatId: target.chatId } : { userId: target.userId }),
        text,
        ...(replyToMsgId != null ? { replyToMsgId } : {}),
        sendMode: sendMode === "silent" ? "silent" : undefined,
        parseMarkdown,
      })
      return { messageId: res.messageId, spaceId: chat?.spaceId ?? null }
    },

    async sendMediaMessage({ chatId, userId, media, text, replyToMsgId, sendMode, parseMarkdown }) {
      const target = resolveTarget({ chatId, userId }, "sendMediaMessage")
      if (target.kind === "user" && !allowDms) {
        throw new Error("DM access is not allowed for this grant")
      }

      const chat = target.kind === "chat" ? await getAllowedChat({ chatId: target.chatId }) : null
      const trimmedText = text?.trim()

      await ensureConnected()
      const res = await client.sendMessage({
        ...(target.kind === "chat" ? { chatId: target.chatId } : { userId: target.userId }),
        ...(trimmedText ? { text: trimmedText } : {}),
        media:
          media.kind === "photo"
            ? { kind: "photo", photoId: media.id }
            : media.kind === "video"
              ? { kind: "video", videoId: media.id }
              : { kind: "document", documentId: media.id },
        ...(replyToMsgId != null ? { replyToMsgId } : {}),
        sendMode: sendMode === "silent" ? "silent" : undefined,
        ...(trimmedText ? { parseMarkdown } : {}),
      })
      return { messageId: res.messageId, spaceId: chat?.spaceId ?? null }
    },

  }
}
