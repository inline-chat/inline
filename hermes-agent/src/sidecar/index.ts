import http, { type IncomingMessage, type ServerResponse } from "node:http"
import { once } from "node:events"
import { timingSafeEqual } from "node:crypto"
import { mkdir, readFile, stat } from "node:fs/promises"
import path from "node:path"
import {
  BotCapability_Kind,
  DialogFollowMode,
  InlineSdkClient,
  JsonFileStateStore,
  GetMeInput,
  GetChatInput,
  Method,
  InputPeer,
  registerBotCapabilitiesWithRetry,
  MessageAction,
  MessageActionCallback,
  MessageActionCopyText,
  MessageActionResponseUi,
  MessageActionRow,
  MessageActions,
  MessageActionToast,
  type InlineSdkClientOptions,
  type InlineSdkGetMessagesParams,
  type InlineSdkSendMessageParams,
  type InlineSdkSendMessageMedia,
  type InlineSdkSetBotPresenceStateParams,
  type InlineSdkUploadFileParams,
  type InlineSdkUploadFileResult,
  type BotChatSettingsResponse,
} from "@inline-chat/realtime-sdk"

// The server contract defines UNFOLLOWED = 2, but the currently published
// protocol package predates that generated enum member. Keep the compatibility
// value named and typed until the dependency catches up.
const DIALOG_FOLLOW_MODE_UNFOLLOWED = 2 as DialogFollowMode
import {
  SidecarError,
  asOptionalRecord,
  asRecord,
  normalizeInboundEvent,
  normalizeError,
  normalizeUploadKind,
  parseOptionalInt,
  readInlineIdArray,
  readOptionalInlineId,
  readRequiredInlineId,
  parseTarget,
  redactText,
  redactUrl,
  readOptionalBoolean,
  readOptionalNumber,
  readOptionalString,
  readRequiredString,
  safeJson,
  type GenericInboundEvent,
  type GenericSenderProfile,
  type Json,
  type Target,
} from "./contract.js"
import { InlineUserDirectory } from "./user-directory.js"

const token = process.env.INLINE_TOKEN || process.env.INLINE_BOT_TOKEN || ""
const baseUrl = process.env.INLINE_BASE_URL || "https://api.inline.chat"
const sidecarToken = process.env.INLINE_SIDECAR_TOKEN || ""
const port = normalizeSidecarPort(process.env.INLINE_SIDECAR_PORT)
const bind = normalizeSidecarBind(process.env.INLINE_SIDECAR_BIND)
const statePath = process.env.INLINE_STATE_PATH || path.join(process.cwd(), "inline-sdk-state.json")
const rpcTimeoutMs = parseOptionalInt(process.env.INLINE_RPC_TIMEOUT_MS)
const uploadMaxBytes = Math.floor(normalizePositiveMb(process.env.INLINE_UPLOAD_MAX_MB, 300, "INLINE_UPLOAD_MAX_MB") * 1024 * 1024)
const connectRetryInitialMs = clampRetryMs(parseOptionalInt(process.env.INLINE_CONNECT_RETRY_INITIAL_MS), 1_000)
const connectRetryMaxMs = Math.max(
  connectRetryInitialMs,
  clampRetryMs(parseOptionalInt(process.env.INLINE_CONNECT_RETRY_MAX_MS), 15_000),
)

type RawChat = {
  id?: bigint | number | string | null
  title?: string | null
  peerId?: unknown
  spaceId?: bigint | number | string | null
  parentChatId?: bigint | number | string | null
  parentMessageId?: bigint | number | string | null
  description?: string | null
  emoji?: string | null
  isPublic?: boolean | null
  lastMsgId?: bigint | number | string | null
  date?: bigint | number | string | null
  createdBy?: bigint | number | string | null
  untitled?: boolean | null
  number?: number | null
}

type RawDialog = {
  followMode?: bigint | number | string | null
  follow_mode?: bigint | number | string | null
}

if (!token || !sidecarToken) {
  console.error("inline-sidecar: INLINE_TOKEN/INLINE_BOT_TOKEN and INLINE_SIDECAR_TOKEN are required.")
  process.exit(2)
}

await mkdir(path.dirname(statePath), { recursive: true }).catch(() => {})

let connected = false
let connecting = false
let stopping = false
let meId: string | null = null
let meUsername: string | null = null
let connectError: string | null = null
let connectAttempts = 0
let nextConnectRetryAt: string | null = null
let consumer: ServerResponse | null = null
let consumerWaiters: Array<() => void> = []

const clientOptions: InlineSdkClientOptions = {
  token,
  baseUrl,
  state: new JsonFileStateStore(statePath),
  ...(rpcTimeoutMs != null ? { rpcTimeoutMs } : {}),
  logger: {
    debug: (...args) => log("debug", args),
    info: (...args) => log("info", args),
    warn: (...args) => log("warn", args),
    error: (...args) => log("error", args),
  },
}
async function connectClientLoop() {
  let delayMs = connectRetryInitialMs
  while (!stopping && !connected) {
    connectAttempts += 1
    connecting = true
    nextConnectRetryAt = null
    try {
      await client.connect()
      const meResult = asOptionalRecord(await client.invoke(Method.GET_ME, {
        oneofKind: "getMe",
        getMe: GetMeInput.create({}),
      }))
      const me = asOptionalRecord(asOptionalRecord(meResult?.getMe)?.user)
      if (me?.id == null) throw new Error("getMe: missing user")
      meId = String(me.id)
      meUsername = normalizeOwnUsername(me.username)
      void registerBotCapabilitiesWithRetry({
        register: () => client.setMyBotCapabilities({
          capabilities: [{ kind: BotCapability_Kind.CHAT_SETTINGS, version: 1 }],
        }),
        isCancelled: () => stopping,
        onFailure: (error, willRetry) => console.error(
          `inline-sidecar: capability registration failed: ${redactError(error)}${willRetry ? "; retrying" : ""}`,
        ),
      })
      connected = true
      connecting = false
      connectError = null
      nextConnectRetryAt = null
      console.error(`inline-sidecar: connected as ${meId}`)
      return
    } catch (error) {
      connected = false
      connecting = false
      connectError = redactError(error)
      process.exitCode = 3
      if (stopping) return
      nextConnectRetryAt = new Date(Date.now() + delayMs).toISOString()
      console.error(`inline-sidecar: connect attempt ${connectAttempts} failed: ${connectError}; retrying in ${delayMs}ms`)
      await sleep(delayMs)
      delayMs = Math.min(delayMs * 2, connectRetryMaxMs)
    }
  }
}

async function consumeEvents() {
  try {
    for await (const event of client.events()) {
      const sender = await resolveInboundSender(event)
      await deliver(normalizeInboundEvent(event, meId, sender, meUsername))
    }
  } catch (error) {
    if (!stopping) {
      connected = false
      connecting = false
      connectError = redactError(error)
      console.error(`inline-sidecar: inbound loop failed: ${connectError}; terminating for owner restart`)
      await shutdown(1)
    }
  }
}

async function handleRequest(req: IncomingMessage, res: ServerResponse) {
  const url = new URL(req.url || "/", "http://127.0.0.1")

  if (!authorized(req)) {
    writeJson(res, 401, { ok: false, error: "unauthorized", errorKind: "forbidden" })
    return
  }

  if (req.method === "POST" && url.pathname === "/healthz") {
    writeJson(res, 200, {
      ok: true,
      result: {
        connected,
        connecting,
        meId,
        meUsername,
        baseUrl: redactUrl(baseUrl),
        statePath,
        version: await packageVersion(),
        connectAttempts,
        connectRetryInitialMs,
        connectRetryMaxMs,
        nextConnectRetryAt,
        diagnostics: safeJson(client.getDiagnostics()),
        ...(connectError ? { connectError } : {}),
      },
    })
    return
  }

  if (req.method === "GET" && url.pathname === "/inbound") {
    if (!authorized(req)) {
      writeJson(res, 401, { ok: false, error: "unauthorized", errorKind: "forbidden" })
      return
    }
    attachConsumer(res)
    return
  }

  if (req.method !== "POST") {
    writeJson(res, 405, { ok: false, error: "method not allowed", errorKind: "bad_format" })
    return
  }

  if (!connected && url.pathname !== "/shutdown") {
    writeJson(res, 503, {
      ok: false,
      error: connectError || "Inline SDK is not connected",
      errorKind: "transient",
    })
    return
  }

  const body = await readJsonBody(req)

  switch (url.pathname) {
    case "/send":
      await endpointSend(res, body)
      return
    case "/edit":
      await endpointEdit(res, body)
      return
    case "/delete":
      await endpointDelete(res, body)
      return
    case "/typing":
      await endpointTyping(res, body)
      return
    case "/presence":
      await endpointPresence(res, body)
      return
    case "/send-attachment":
      await endpointSendAttachment(res, body)
      return
    case "/chat":
      await endpointChat(res, body)
      return
    case "/follow-mode":
      await endpointFollowMode(res, body)
      return
    case "/messages":
      await endpointMessages(res, body)
      return
    case "/history":
      await endpointHistory(res, body)
      return
    case "/search":
      await endpointSearch(res, body)
      return
    case "/reaction":
      await endpointReaction(res, body)
      return
    case "/reactions":
      await endpointReactions(res, body)
      return
    case "/pin":
      await endpointPin(res, body)
      return
    case "/pins":
      await endpointPins(res, body)
      return
    case "/create-subthread":
      await endpointCreateSubthread(res, body)
      return
    case "/create-chat":
      await endpointCreateChat(res, body)
      return
    case "/create-agent":
      await endpointCreateAgent(res, body)
      return
    case "/get-agent":
      await endpointGetAgent(res, body)
      return
    case "/answer-action":
      await endpointAnswerAction(res, body)
      return
    case "/answer-bot-settings":
      await endpointAnswerBotSettings(res, body)
      return
    case "/shutdown":
      writeJson(res, 200, { ok: true, result: {} })
      void shutdown(0)
      return
    default:
      writeJson(res, 404, { ok: false, error: "not found", errorKind: "not_found" })
  }
}

async function endpointSend(res: ServerResponse, body: unknown) {
  const record = asRecord(body)
  const target = parseTarget(record)
  const text = readOptionalString(record, "text")
  const replyToMsgId = readOptionalInlineId(record, "replyToMsgId")
  const parseMarkdown = readOptionalBoolean(record, "parseMarkdown") ?? true
  const actions = parseActions(record.actions)
  const sendMode = readOptionalString(record, "sendMode")
  const media = parseSendMedia(record.media)

  if (!text && !media) {
    throw new SidecarError("send requires text or media", "bad_format")
  }

  const params = {
    ...(text ? { text } : {}),
    ...(media ? { media } : {}),
    ...(replyToMsgId ? { replyToMsgId } : {}),
    parseMarkdown,
    ...(actions ? { actions } : {}),
    ...(sendMode === "silent" ? { sendMode: "silent" as const } : {}),
  }
  const result = "chatId" in target
    ? await client.sendMessage({ chatId: target.chatId, ...params })
    : await client.sendMessage({ userId: target.userId, ...params })
  writeJson(res, 200, { ok: true, result: { messageId: result.messageId?.toString() ?? null } })
}

async function endpointEdit(res: ServerResponse, body: unknown) {
  const record = asRecord(body)
  const target = parseTarget(record)
  const messageId = readRequiredInlineId(record, "messageId")
  const text = readRequiredString(record, "text")
  const actions = parseActions(record.actions)
  const parseMarkdown = readOptionalBoolean(record, "parseMarkdown") ?? true

  await client.invoke(Method.EDIT_MESSAGE, {
    oneofKind: "editMessage",
    editMessage: {
      peerId: inputPeerFromTarget(target),
      messageId,
      text,
      parseMarkdown,
      ...(actions ? { actions } : {}),
    },
  })
  writeJson(res, 200, { ok: true, result: { messageId: messageId.toString() } })
}

async function endpointDelete(res: ServerResponse, body: unknown) {
  const record = asRecord(body)
  const target = parseTarget(record)
  const messageId = readRequiredInlineId(record, "messageId")

  await client.invoke(Method.DELETE_MESSAGES, {
    oneofKind: "deleteMessages",
    deleteMessages: {
      peerId: inputPeerFromTarget(target),
      messageIds: [messageId],
    },
  })
  writeJson(res, 200, { ok: true, result: { messageId: messageId.toString() } })
}

async function endpointTyping(res: ServerResponse, body: unknown) {
  const record = asRecord(body)
  const target = parseTarget(record)
  const typing = (readOptionalString(record, "state") ?? "start") !== "stop"
  if ("userId" in target) {
    writeJson(res, 200, { ok: true, result: { skipped: "typing is chat-only" } })
    return
  }
  await client.sendTyping({ chatId: target.chatId, typing })
  writeJson(res, 200, { ok: true, result: {} })
}

async function endpointPresence(res: ServerResponse, body: unknown) {
  const record = asRecord(body)
  const target = parseTarget(record)
  const kind = readRequiredString(record, "kind") as InlineSdkSetBotPresenceStateParams["kind"]
  const comment = readOptionalString(record, "comment")
  if ("chatId" in target) {
    await client.setBotPresenceState({ chatId: target.chatId, kind, ...(comment ? { comment } : {}) })
  } else {
    await client.setBotPresenceState({ userId: target.userId, kind, ...(comment ? { comment } : {}) })
  }
  writeJson(res, 200, { ok: true, result: {} })
}

async function endpointSendAttachment(res: ServerResponse, body: unknown) {
  const record = asRecord(body)
  const target = parseTarget(record)
  const filePath = readRequiredString(record, "path")
  const kind = normalizeUploadKind(readOptionalString(record, "kind"), filePath)
  const caption = readOptionalString(record, "caption")
  const replyToMsgId = readOptionalInlineId(record, "replyToMsgId")
  const fileName = readOptionalString(record, "fileName") || path.basename(filePath)
  const contentType = readOptionalString(record, "mimeType")
  const info = await statAttachment(filePath)
  if (info.size > uploadMaxBytes) {
    throw new SidecarError(`attachment exceeds Inline upload cap (${info.size} > ${uploadMaxBytes} bytes)`, "too_long")
  }
  const upload = await client.uploadFile({
    type: kind,
    file: await readFile(filePath),
    fileName,
    ...(contentType ? { contentType } : {}),
  })
  const media =
    kind === "photo" && upload.photoId != null
      ? { kind: "photo" as const, photoId: upload.photoId }
      : kind === "video" && upload.videoId != null
        ? { kind: "video" as const, videoId: upload.videoId }
        : upload.documentId != null
          ? { kind: "document" as const, documentId: upload.documentId }
          : null
  if (!media) throw new SidecarError("upload did not return a sendable media id", "unknown")
  const sendParams = {
    media,
    ...(caption ? { text: caption, parseMarkdown: true } : {}),
    ...(replyToMsgId ? { replyToMsgId } : {}),
  }
  const sent = "chatId" in target
    ? await client.sendMessage({ chatId: target.chatId, ...sendParams })
    : await client.sendMessage({ userId: target.userId, ...sendParams })
  writeJson(res, 200, {
    ok: true,
    result: {
      messageId: sent.messageId?.toString() ?? null,
      fileUniqueId: upload.fileUniqueId,
    },
  })
}

async function statAttachment(filePath: string) {
  if (!path.isAbsolute(filePath)) {
    throw new SidecarError("attachment path must be absolute", "bad_format")
  }

  let info: Awaited<ReturnType<typeof stat>>
  try {
    info = await stat(filePath)
  } catch (error) {
    if (hasNodeErrorCode(error, "ENOENT", "ENOTDIR")) {
      throw new SidecarError("attachment path does not exist", "not_found")
    }
    if (hasNodeErrorCode(error, "EACCES", "EPERM")) {
      throw new SidecarError("attachment path is not readable", "forbidden")
    }
    throw error
  }

  if (!info.isFile()) {
    throw new SidecarError("attachment path must be a regular file", "bad_format")
  }

  return info
}

function hasNodeErrorCode(error: unknown, ...codes: string[]): boolean {
  return Boolean(
    error &&
      typeof error === "object" &&
      "code" in error &&
      typeof error.code === "string" &&
      codes.includes(error.code),
  )
}

async function endpointChat(res: ServerResponse, body: unknown) {
  const record = asRecord(body)
  const target = parseTarget(record)
  if ("userId" in target) {
    const sender = await userDirectory.resolve({ userId: target.userId, chatId: target.userId, direct: true })
    writeJson(res, 200, {
      ok: true,
      result: {
        id: target.userId.toString(),
        title: senderDisplayName(sender) ?? "Direct message",
        type: "dm",
      },
    })
    return
  }
  const snapshot = await getRawChatSnapshot(target.chatId)
  const chat = snapshot.chat
  const anchorMessages = snapshot.anchorMessage != null
    ? await enrichMessages([snapshot.anchorMessage], target)
    : []
  const anchorMessage = anchorMessages[0]
  writeJson(res, 200, {
    ok: true,
    result: {
      chatId: chat.id?.toString() ?? target.chatId.toString(),
      title: chat.title ?? "",
      ...(chat.peerId != null ? { peer: safeJson(chat.peerId) } : {}),
      ...(chat.spaceId != null ? { spaceId: chat.spaceId.toString() } : {}),
      ...(chat.parentChatId != null ? { parentChatId: chat.parentChatId.toString() } : {}),
      ...(chat.parentMessageId != null ? { parentMessageId: chat.parentMessageId.toString() } : {}),
      ...(chat.description != null ? { description: chat.description } : {}),
      ...(chat.emoji != null ? { emoji: chat.emoji } : {}),
      ...(chat.isPublic != null ? { isPublic: chat.isPublic } : {}),
      ...(chat.lastMsgId != null ? { lastMsgId: chat.lastMsgId.toString() } : {}),
      ...(chat.date != null ? { date: chat.date.toString() } : {}),
      ...(chat.createdBy != null ? { createdBy: chat.createdBy.toString() } : {}),
      ...(chat.untitled != null ? { untitled: chat.untitled } : {}),
      ...(chat.number != null ? { number: chat.number } : {}),
      ...(snapshot.dialog != null ? { dialog: safeJson(snapshot.dialog) } : {}),
      ...(snapshot.dialogFollowMode != null ? { dialogFollowMode: String(snapshot.dialogFollowMode) } : {}),
      pinnedMessageIds: safeJson(snapshot.pinnedMessageIds),
      ...(anchorMessage != null ? { anchorMessage: safeJson(anchorMessage) } : {}),
      chat: safeJson(chat),
    },
  })
}

async function endpointFollowMode(res: ServerResponse, body: unknown) {
  const record = asRecord(body)
  const target = parseTarget(record)
  const mode = readRequiredString(record, "mode")
  const followMode = mode === "following"
    ? DialogFollowMode.FOLLOWING
    : mode === "unfollowed" ? DIALOG_FOLLOW_MODE_UNFOLLOWED : null
  if (followMode == null) {
    throw new SidecarError("mode must be following or unfollowed", "bad_format")
  }
  await client.invokeUncheckedRaw(Method.UPDATE_DIALOG_FOLLOW_MODE, {
    oneofKind: "updateDialogFollowMode",
    updateDialogFollowMode: {
      peerId: inputPeerFromTarget(target),
      followMode,
    },
  })
  writeJson(res, 200, { ok: true, result: { mode } })
}

async function endpointMessages(res: ServerResponse, body: unknown) {
  const record = asRecord(body)
  const target = parseTarget(record)
  const messageIds = readInlineIdArray(record, "messageIds", 100, true)
  const result = "chatId" in target
    ? await client.getMessages({ chatId: target.chatId, messageIds })
    : await client.getMessages({ userId: target.userId, messageIds })
  const ordered = orderMessagesByRequestedIds(result.messages, messageIds)
  writeJson(res, 200, { ok: true, result: { messages: safeJson(await enrichMessages(ordered, target)) } })
}

async function endpointHistory(res: ServerResponse, body: unknown) {
  const record = asRecord(body)
  const target = parseTarget(record)
  const limit = readOptionalNumber(record, "limit") ?? 20
  const anchorId = readOptionalInlineId(record, "anchorId")
  const result = await client.invoke(Method.GET_CHAT_HISTORY, {
    oneofKind: "getChatHistory",
    getChatHistory: {
      peerId: inputPeerFromTarget(target),
      limit,
      ...(anchorId ? { anchorId, includeAnchor: true } : {}),
    },
  })
  const history = result as { getChatHistory?: { messages?: unknown[] } }
  const messages = history.getChatHistory?.messages ?? []
  writeJson(res, 200, { ok: true, result: { messages: safeJson(await enrichMessages(messages, target)) } })
}

async function endpointSearch(res: ServerResponse, body: unknown) {
  const record = asRecord(body)
  const target = parseTarget(record)
  const query = readRequiredString(record, "query").trim()
  if (!query) throw new SidecarError("search requires query", "bad_format")
  const limit = clampResultLimit(readOptionalNumber(record, "limit") ?? 20, 100)
  const offsetId = readOptionalInlineId(record, "offsetId")
  const result = await client.invokeUncheckedRaw(Method.SEARCH_MESSAGES, {
    oneofKind: "searchMessages",
    searchMessages: {
      peerId: inputPeerFromTarget(target),
      queries: [query],
      limit,
      ...(offsetId ? { offsetId } : {}),
    },
  })
  const typed = result as { oneofKind?: string; searchMessages?: { messages?: unknown[] } }
  const messages = typed.searchMessages?.messages ?? []
  writeJson(res, 200, { ok: true, result: { messages: safeJson(await enrichMessages(messages, target)) } })
}

async function endpointReaction(res: ServerResponse, body: unknown) {
  const record = asRecord(body)
  const target = parseTarget(record)
  const messageId = readRequiredInlineId(record, "messageId")
  const emoji = readRequiredString(record, "emoji").trim()
  if (!emoji) throw new SidecarError("reaction requires emoji", "bad_format")
  const remove = readOptionalBoolean(record, "remove") ?? false

  if (remove) {
    await client.invokeUncheckedRaw(Method.DELETE_REACTION, {
      oneofKind: "deleteReaction",
      deleteReaction: {
        emoji,
        peerId: inputPeerFromTarget(target),
        messageId,
      },
    })
  } else {
    await client.invokeUncheckedRaw(Method.ADD_REACTION, {
      oneofKind: "addReaction",
      addReaction: {
        emoji,
        messageId,
        peerId: inputPeerFromTarget(target),
      },
    })
  }
  writeJson(res, 200, { ok: true, result: { messageId: messageId.toString(), emoji, removed: remove } })
}

async function endpointReactions(res: ServerResponse, body: unknown) {
  const record = asRecord(body)
  const target = parseTarget(record)
  const messageId = readRequiredInlineId(record, "messageId")
  const result = "chatId" in target
    ? await client.getMessages({ chatId: target.chatId, messageIds: [messageId] })
    : await client.getMessages({ userId: target.userId, messageIds: [messageId] })
  const message = result.messages[0] ?? null
  const enriched = message == null ? null : (await enrichMessages([message], target))[0] ?? message
  writeJson(res, 200, {
    ok: true,
    result: {
      message: safeJson(enriched),
      reactions: safeJson(reactionsFromMessage(message)),
    },
  })
}

async function endpointPin(res: ServerResponse, body: unknown) {
  const record = asRecord(body)
  const target = parseTarget(record)
  const messageId = readRequiredInlineId(record, "messageId")
  const unpin = readOptionalBoolean(record, "unpin") ?? false
  await client.invokeUncheckedRaw(Method.PIN_MESSAGE, {
    oneofKind: "pinMessage",
    pinMessage: {
      peerId: inputPeerFromTarget(target),
      messageId,
      unpin,
    },
  })
  writeJson(res, 200, { ok: true, result: { messageId: messageId.toString(), unpinned: unpin } })
}

async function endpointPins(res: ServerResponse, body: unknown) {
  const record = asRecord(body)
  const target = parseTarget(record)
  if ("userId" in target) {
    throw new SidecarError("pins requires a chat target", "bad_format")
  }
  const snapshot = await getRawChatSnapshot(target.chatId)
  const anchorMessages = snapshot.anchorMessage != null
    ? await enrichMessages([snapshot.anchorMessage], target)
    : []
  const anchorMessage = anchorMessages[0]
  writeJson(res, 200, {
    ok: true,
    result: {
      chatId: target.chatId.toString(),
      pinnedMessageIds: safeJson(snapshot.pinnedMessageIds),
      ...(anchorMessage != null ? { anchorMessage: safeJson(anchorMessage) } : {}),
    },
  })
}

async function endpointCreateSubthread(res: ServerResponse, body: unknown) {
  const record = asRecord(body)
  const parentChatId = readRequiredInlineId(record, "parentChatId")
  const parentMessageId = readOptionalInlineId(record, "parentMessageId")
  const title = readOptionalString(record, "title")
  const description = readOptionalString(record, "description")
  const emoji = readOptionalString(record, "emoji")

  const result = await client.invokeUncheckedRaw(Method.CREATE_SUBTHREAD, {
    oneofKind: "createSubthread",
    createSubthread: {
      parentChatId,
      participants: [],
      ...(parentMessageId ? { parentMessageId } : {}),
      ...(title ? { title } : {}),
      ...(description ? { description } : {}),
      ...(emoji ? { emoji } : {}),
    },
  })
  const typed = result as {
    oneofKind?: string
    createSubthread?: { chat?: { id?: bigint | number | string | null } & Record<string, unknown> }
  }
  const subthread = typed.oneofKind === "createSubthread" ? typed.createSubthread?.chat : undefined
  writeJson(res, 200, {
    ok: true,
    result: {
      chat: safeJson(subthread ?? null),
      chatId: subthread?.id?.toString() ?? null,
    },
  })
}

async function endpointCreateChat(res: ServerResponse, body: unknown) {
  const record = asRecord(body)
  const title = readRequiredString(record, "title")
  const description = readOptionalString(record, "description")
  const emoji = readOptionalString(record, "emoji")
  const spaceId = readOptionalInlineId(record, "spaceId")
  const isPublic = readOptionalBoolean(record, "isPublic") ?? false
  const participantUserIds = readInlineIdArray(record, "participantUserIds", 50)

  if (title.length > 200) throw new SidecarError("create-chat title is too long", "bad_format")
  if (description && description.length > 1_000) {
    throw new SidecarError("create-chat description is too long", "bad_format")
  }
  if (emoji && emoji.length > 16) throw new SidecarError("create-chat emoji is too long", "bad_format")
  if (isPublic && spaceId == null) {
    throw new SidecarError("public create-chat requires spaceId", "bad_format")
  }
  if (isPublic && participantUserIds.length > 0) {
    throw new SidecarError("public create-chat cannot include participantUserIds", "bad_format")
  }

  const result = await client.invokeUncheckedRaw(Method.CREATE_CHAT, {
    oneofKind: "createChat",
    createChat: {
      title,
      ...(spaceId != null ? { spaceId } : {}),
      ...(description ? { description } : {}),
      ...(emoji ? { emoji } : {}),
      isPublic,
      participants: participantUserIds.map((userId) => ({ userId })),
    },
  })
  const typed = result as {
    oneofKind?: string
    createChat?: {
      chat?: { id?: bigint | number | string | null } & Record<string, unknown>
      dialog?: Record<string, unknown>
    }
  }
  if (typed.oneofKind !== "createChat" || typed.createChat?.chat?.id == null) {
    throw new SidecarError("create-chat returned no chat", "unknown")
  }
  writeJson(res, 200, {
    ok: true,
    result: {
      chat: safeJson(typed.createChat.chat),
      chatId: String(typed.createChat.chat.id),
      dialog: safeJson(typed.createChat.dialog ?? null),
    },
  })
}

async function callBotApi(
  methodName: string,
  method: "GET" | "POST",
  body?: Record<string, unknown>,
  query?: Record<string, string>,
): Promise<Record<string, unknown>> {
  const url = new URL(`/bot/${methodName}`, baseUrl)
  for (const [key, value] of Object.entries(query ?? {})) url.searchParams.set(key, value)
  const response = await fetch(url, {
    method,
    headers: {
      authorization: `Bearer ${token}`,
      ...(body ? { "content-type": "application/json" } : {}),
    },
    ...(body ? { body: JSON.stringify(body) } : {}),
  })
  const payload = asOptionalRecord(await response.json().catch(() => null))
  if (!response.ok || payload?.ok !== true) {
    throw new SidecarError(String(payload?.description ?? `Bot API HTTP ${response.status}`), "unknown")
  }
  return asOptionalRecord(payload.result) ?? {}
}

async function endpointCreateAgent(res: ServerResponse, body: unknown) {
  const record = asRecord(body)
  const name = readRequiredString(record, "name")
  const result = await callBotApi("createAgent", "POST", {
    name,
    ...(readOptionalString(record, "handle") ? { handle: readOptionalString(record, "handle") } : {}),
    ...(readOptionalString(record, "emoji") ? { emoji: readOptionalString(record, "emoji") } : {}),
    ...(readOptionalString(record, "description") ? { description: readOptionalString(record, "description") } : {}),
    ...(readOptionalString(record, "skill_key") ? { skill_key: readOptionalString(record, "skill_key") } : {}),
    ...(readOptionalString(record, "instructions") ? { instructions: readOptionalString(record, "instructions") } : {}),
  })
  const agent = asOptionalRecord(result.agent)
  if (!agent) {
    throw new SidecarError("create-agent returned no Agent", "unknown")
  }
  writeJson(res, 200, { ok: true, result: { agent: safeJson(agent) } })
}

async function endpointGetAgent(res: ServerResponse, body: unknown) {
  const record = asRecord(body)
  const agentId = readRequiredInlineId(record, "agentId")
  const result = await callBotApi("getAgent", "GET", undefined, { agent_id: String(agentId) })
  if (!asOptionalRecord(result.agent)) {
    throw new SidecarError("Agent not found", "not_found")
  }
  writeJson(res, 200, { ok: true, result: safeJson(result) })
}

async function getRawChatSnapshot(chatId: bigint): Promise<{
  chat: RawChat
  dialog?: RawDialog
  dialogFollowMode?: bigint | number | string
  pinnedMessageIds: unknown[]
  anchorMessage?: unknown
}> {
  const result = await client.invoke(Method.GET_CHAT, {
    oneofKind: "getChat",
    getChat: GetChatInput.create({ peerId: inputPeerFromTarget({ chatId }) }),
  })
  const typed = result as {
    getChat?: {
      chat?: RawChat
      dialog?: RawDialog
      pinnedMessageIds?: unknown[]
      anchorMessage?: unknown
    }
  }
  const chat = typed.getChat?.chat
  if (!chat) throw new SidecarError("chat not found", "not_found")
  const dialog = typed.getChat?.dialog
  const dialogFollowMode = dialog?.followMode ?? dialog?.follow_mode ?? undefined
  return {
    chat,
    ...(dialog != null ? { dialog } : {}),
    ...(dialogFollowMode != null ? { dialogFollowMode } : {}),
    pinnedMessageIds: typed.getChat?.pinnedMessageIds ?? [],
    ...(typed.getChat?.anchorMessage != null ? { anchorMessage: typed.getChat.anchorMessage } : {}),
  }
}

function reactionsFromMessage(message: unknown): unknown {
  if (!message || typeof message !== "object" || !("reactions" in message)) return null
  return (message as { reactions?: unknown }).reactions ?? null
}

function senderDisplayName(sender: GenericSenderProfile | undefined): string | null {
  if (!sender) return null
  const fullName = [sender.firstName?.trim(), sender.lastName?.trim()].filter(Boolean).join(" ")
  if (fullName) return fullName
  const username = sender.username?.trim().replace(/^@/, "")
  return username ? `@${username}` : null
}

async function enrichMessages(messages: unknown[], target: Target): Promise<unknown[]> {
  return Promise.all(messages.map(async (message) => {
    const record = asOptionalRecord(message)
    if (!record) return message
    const userId = asPositiveBigInt(record.fromId)
    const chatId = "chatId" in target ? target.chatId : asPositiveBigInt(record.chatId)
    if (!userId || !chatId) return message
    const sender = await userDirectory.resolve({
      userId,
      chatId,
      direct: "userId" in target || messagePeerIsDirect(record),
    })
    return sender ? { ...record, sender } : message
  }))
}

function orderMessagesByRequestedIds(messages: unknown[], requestedIds: bigint[]): unknown[] {
  const byId = new Map<string, unknown>()
  for (const message of messages) {
    const record = asOptionalRecord(message)
    const id = asPositiveBigInt(record?.id)
    if (id && !byId.has(id.toString())) byId.set(id.toString(), message)
  }
  return requestedIds.flatMap((id) => {
    const message = byId.get(id.toString())
    return message == null ? [] : [message]
  })
}

async function resolveInboundSender(event: GenericInboundEvent): Promise<GenericSenderProfile | undefined> {
  const message = asOptionalRecord(event.message)
  const reaction = asOptionalRecord(event.reaction)
  const participant = asOptionalRecord(event.participant)
  const userId = asPositiveBigInt(
    message?.fromId
      ?? event.actorUserId
      ?? reaction?.userId
      ?? event.userId
      ?? participant?.userId,
  )
  const chatId = asPositiveBigInt(event.chatId ?? message?.chatId ?? reaction?.chatId)
  if (!userId || !chatId || userId.toString() === meId) return undefined
  return userDirectory.resolve({
    userId,
    chatId,
    direct: message ? messagePeerIsDirect(message) : false,
  })
}

function messagePeerIsDirect(message: Record<string, unknown>): boolean {
  const peer = asOptionalRecord(message.peerId)
  const type = asOptionalRecord(peer?.type)
  return type?.oneofKind === "user"
}

function asPositiveBigInt(value: unknown): bigint | null {
  if (value == null) return null
  try {
    const parsed = BigInt(String(value))
    return parsed > 0n ? parsed : null
  } catch {
    return null
  }
}

function clampResultLimit(value: number, max: number): number {
  if (!Number.isInteger(value) || value < 1) {
    throw new SidecarError("limit must be a positive integer", "bad_format")
  }
  return Math.min(value, max)
}

async function endpointAnswerAction(res: ServerResponse, body: unknown) {
  const record = asRecord(body)
  const interactionId = readRequiredInlineId(record, "interactionId")
  const toastText = readOptionalString(record, "toast")
  await client.answerMessageAction({
    interactionId,
    ...(toastText ? { ui: MessageActionResponseUi.create({
      kind: { oneofKind: "toast", toast: MessageActionToast.create({ text: toastText }) },
    }) } : {}),
  })
  writeJson(res, 200, { ok: true, result: {} })
}

async function endpointAnswerBotSettings(res: ServerResponse, body: unknown) {
  const record = asRecord(body)
  const requestId = readRequiredInlineId(record, "requestId")
  const response = asRecord(record.response) as unknown as BotChatSettingsResponse
  await client.answerBotChatSettings({ requestId, response })
  writeJson(res, 200, { ok: true, result: {} })
}

type SidecarClient = {
  connect(): Promise<void>
  close(): Promise<void>
  getDiagnostics(): unknown
  events(): AsyncIterable<GenericInboundEvent>
  getChat(params: { chatId: bigint }): Promise<{
    chatId: bigint
    title: string
    peer?: unknown
    spaceId?: bigint
    parentChatId?: bigint
    parentMessageId?: bigint
    lastMsgId?: bigint
    dialogFollowMode?: bigint | number | string
    isPublic?: boolean
    untitled?: boolean
    number?: number
  }>
  getMessages(params: InlineSdkGetMessagesParams): Promise<{ messages: unknown[] }>
  sendMessage(params: InlineSdkSendMessageParams): Promise<{ messageId: bigint | null }>
  uploadFile(params: InlineSdkUploadFileParams): Promise<InlineSdkUploadFileResult>
  sendTyping(params: { chatId: bigint; typing: boolean }): Promise<void>
  setBotPresenceState(params: InlineSdkSetBotPresenceStateParams): Promise<void>
  answerMessageAction(params: { interactionId: bigint; ui?: unknown }): Promise<void>
  setMyBotCapabilities(params: { capabilities: Array<{ kind: BotCapability_Kind; version: number }> }): Promise<unknown>
  answerBotChatSettings(params: { requestId: bigint; response: BotChatSettingsResponse }): Promise<void>
  invoke(method: Method, input: unknown): Promise<unknown>
  invokeUncheckedRaw(method: Method, input: unknown): Promise<unknown>
}

function createClient(options: InlineSdkClientOptions): SidecarClient {
  if (testMockEnabled(options)) {
    return new MockInlineClient()
  }
  return new InlineSdkClient(options) as unknown as SidecarClient
}

function testMockEnabled(options: InlineSdkClientOptions): boolean {
  if (readEnv("INLINE_SIDECAR_TEST_MOCK") !== "1" || readEnv("INLINE_SIDECAR_TEST_ALLOW_MOCK") !== "1") {
    return false
  }
  return isLoopbackBaseUrl(options.baseUrl || baseUrl)
}

function isLoopbackBaseUrl(value: string): boolean {
  try {
    const url = new URL(value)
    return (url.protocol === "http:" || url.protocol === "https:")
      && (url.hostname === "127.0.0.1" || url.hostname === "localhost" || url.hostname === "[::1]")
  } catch {
    return false
  }
}

function readEnv(name: string): string {
  return process.env[name] || ""
}

function normalizeOwnUsername(value: unknown): string | null {
  if (typeof value !== "string") return null
  const username = value.trim().replace(/^@/, "")
  return username || null
}

function normalizeSidecarBind(value: string | undefined): string {
  const host = (value || "").trim() || "127.0.0.1"
  if (host === "127.0.0.1" || host === "localhost" || host === "::1") return host
  if (host === "[::1]") return "::1"
  console.error(`inline-sidecar: INLINE_SIDECAR_BIND must be loopback (127.0.0.1, localhost, or ::1), got ${host}`)
  process.exit(2)
}

function normalizeSidecarPort(value: string | undefined): number {
  const raw = (value || "").trim()
  if (!raw) return 8794
  if (!/^\d+$/.test(raw)) {
    console.error("inline-sidecar: INLINE_SIDECAR_PORT must be an integer from 1 to 65535")
    process.exit(2)
  }
  const parsed = Number.parseInt(raw, 10)
  if (!Number.isInteger(parsed) || parsed < 1 || parsed > 65_535) {
    console.error("inline-sidecar: INLINE_SIDECAR_PORT must be an integer from 1 to 65535")
    process.exit(2)
  }
  return parsed
}

function normalizePositiveMb(value: string | undefined, fallback: number, name: string): number {
  const raw = (value || "").trim()
  if (!raw) return fallback
  const parsed = Number(raw)
  if (!Number.isFinite(parsed) || parsed <= 0) {
    console.error(`inline-sidecar: ${name} must be a positive number of megabytes`)
    process.exit(2)
  }
  return parsed
}

class MockInlineClient implements SidecarClient {
  private closed = false
  private messageId = 9000n
  private uploadId = 7000n
  private readonly calls: Json[] = []

  async connect(): Promise<void> {
    this.record("connect")
  }

  async close(): Promise<void> {
    this.closed = true
    this.record("close")
  }

  async setMyBotCapabilities(params: { capabilities: Array<{ kind: BotCapability_Kind; version: number }> }): Promise<unknown> {
    this.record("setMyBotCapabilities", params)
    return params
  }

  async answerBotChatSettings(params: { requestId: bigint; response: BotChatSettingsResponse }): Promise<void> {
    this.record("answerBotChatSettings", params)
  }

  getDiagnostics(): unknown {
    return {
      started: !this.closed,
      mock: true,
      calls: this.calls,
    }
  }

  events(): AsyncIterable<GenericInboundEvent> {
    return {
      [Symbol.asyncIterator]: () => ({
        next: async () => {
          while (!this.closed) {
            await sleep(1_000)
          }
          return { done: true, value: undefined }
        },
      }),
    }
  }

  async getChat(params: { chatId: bigint }): Promise<{
    chatId: bigint
    title: string
    parentChatId?: bigint
    parentMessageId?: bigint
    lastMsgId?: bigint
    dialogFollowMode?: bigint | number | string
    untitled?: boolean
  }> {
    this.record("getChat", params)
    if (params.chatId === 456n) {
      return {
        chatId: params.chatId,
        title: "Mock reply thread 456",
        parentChatId: 123n,
        parentMessageId: 9001n,
        lastMsgId: 9002n,
        dialogFollowMode: 1,
        untitled: true,
      }
    }
    return { chatId: params.chatId, title: `Mock chat ${params.chatId.toString()}` }
  }

  async getMessages(params: InlineSdkGetMessagesParams): Promise<{ messages: unknown[] }> {
    this.record("getMessages", params)
    return {
      // Deliberately return server order opposite to requested order so the
      // exact-ID endpoint must restore the caller's first-seen order.
      messages: [...params.messageIds].reverse().map((id) => ({
        id: BigInt(id),
        fromId: 111n,
        chatId: "chatId" in params ? BigInt(params.chatId) : undefined,
        peerId: "chatId" in params
          ? { type: { oneofKind: "chat", chat: { chatId: BigInt(params.chatId) } } }
          : { type: { oneofKind: "user", user: { userId: BigInt(params.userId) } } },
        message: `mock message ${id.toString()}`,
        date: 123n,
        reactions: {
          reactions: [{
            emoji: "ok",
            userId: 222n,
            messageId: BigInt(id),
            chatId: "chatId" in params ? BigInt(params.chatId) : 0n,
            date: 125n,
          }],
        },
      })),
    }
  }

  async sendMessage(params: InlineSdkSendMessageParams): Promise<{ messageId: bigint | null }> {
    this.record("sendMessage", params)
    this.messageId += 1n
    return { messageId: this.messageId }
  }

  async uploadFile(params: InlineSdkUploadFileParams): Promise<InlineSdkUploadFileResult> {
    this.record("uploadFile", {
      type: params.type,
      fileName: params.fileName,
      contentType: params.contentType,
      size: binarySize(params.file),
    })
    this.uploadId += 1n
    const fileUniqueId = `mock-file-${this.uploadId.toString()}`
    if (params.type === "photo") return { fileUniqueId, photoId: this.uploadId }
    if (params.type === "video") return { fileUniqueId, videoId: this.uploadId }
    return { fileUniqueId, documentId: this.uploadId }
  }

  async sendTyping(params: { chatId: bigint; typing: boolean }): Promise<void> {
    this.record("sendTyping", params)
  }

  async setBotPresenceState(params: InlineSdkSetBotPresenceStateParams): Promise<void> {
    this.record("setBotPresenceState", params)
  }

  async answerMessageAction(params: { interactionId: bigint; ui?: unknown }): Promise<void> {
    this.record("answerMessageAction", params)
  }

  async invoke(method: Method, input: unknown): Promise<unknown> {
    this.record(`invoke:${methodName(method)}`, input)
    if (method === Method.GET_ME) {
      return {
        getMe: {
          user: { id: 999n, username: "mock_inline_bot" },
        },
      }
    }
    if (method === Method.GET_CHAT) {
      const inputRecord = asOptionalRecord(input)
      const getChat = asOptionalRecord(inputRecord?.getChat)
      const chatId = chatIdFromInputPeer(getChat?.peerId) ?? 123n
      const chat: RawChat = chatId === 456n
        ? {
            id: chatId,
            title: "Mock reply thread 456",
            parentChatId: 123n,
            parentMessageId: 9001n,
            lastMsgId: 9002n,
            untitled: true,
          }
        : {
            id: chatId,
            title: `Mock chat ${chatId.toString()}`,
          }
      return {
        getChat: {
          chat,
          dialog: { chatId, followMode: chatId === 456n ? 1 : 0 },
          pinnedMessageIds: [8805n, 8801n],
          anchorMessage: {
            id: 8801n,
            fromId: 111n,
            chatId,
            message: "mock pinned message",
            date: 126n,
          },
        },
      }
    }
    if (method === Method.GET_CHAT_HISTORY) {
      return {
        getChatHistory: {
          messages: [
            {
              id: 8700n,
              fromId: 111n,
              chatId: 123n,
              peerId: { type: { oneofKind: "chat", chat: { chatId: 123n } } },
              message: "mock history server-first",
              date: 120n,
            },
            {
              id: 8801n,
              fromId: 111n,
              chatId: 123n,
              peerId: { type: { oneofKind: "chat", chat: { chatId: 123n } } },
              message: "mock history server-second",
              date: 124n,
            },
          ],
        },
      }
    }
    return {}
  }

  async invokeUncheckedRaw(method: Method, input: unknown): Promise<unknown> {
    this.record(`invokeUncheckedRaw:${methodName(method)}`, input)
    if (method === Method.GET_CHAT_PARTICIPANTS) {
      return {
        oneofKind: "getChatParticipants",
        getChatParticipants: {
          users: [{ id: 111n, firstName: "Ada", lastName: "Lovelace", username: "ada" }],
        },
      }
    }
    if (method === Method.CREATE_SUBTHREAD) {
      return {
        oneofKind: "createSubthread",
        createSubthread: {
          chat: {
            id: 321n,
            title: "Mock subthread",
          },
        },
      }
    }
    if (method === Method.CREATE_CHAT) {
      const inputRecord = asOptionalRecord(input)
      const createChat = asOptionalRecord(inputRecord?.createChat)
      return {
        oneofKind: "createChat",
        createChat: {
          chat: {
            id: 322n,
            title: String(createChat?.title ?? "Mock top-level thread"),
            ...(createChat?.spaceId != null ? { spaceId: createChat.spaceId } : {}),
            isPublic: Boolean(createChat?.isPublic),
          },
          dialog: { chatId: 322n },
        },
      }
    }
    if (method === Method.SEARCH_MESSAGES) {
      const inputRecord = asOptionalRecord(input)
      const searchMessages = asOptionalRecord(inputRecord?.searchMessages)
      const peerId = searchMessages?.peerId
      const chatId = chatIdFromInputPeer(peerId) ?? 123n
      const queries = Array.isArray(searchMessages?.queries) ? searchMessages.queries : []
      return {
        oneofKind: "searchMessages",
        searchMessages: {
          messages: [
            {
              id: 8802n,
              fromId: 111n,
              chatId,
              peerId,
              message: `mock search first ${String(queries[0] ?? "")}`.trim(),
              date: 127n,
            },
            {
              id: 8702n,
              fromId: 111n,
              chatId,
              peerId,
              message: `mock search second ${String(queries[0] ?? "")}`.trim(),
              date: 125n,
            },
          ],
        },
      }
    }
    if (method === Method.GET_CHATS) {
      return {
        oneofKind: "getChats",
        getChats: {
          users: [
            { id: 42n, firstName: "Grace", lastName: "Hopper", username: "grace" },
            { id: 111n, firstName: "Ada", lastName: "Lovelace", username: "ada" },
          ],
        },
      }
    }
    if (method === Method.ADD_REACTION) {
      return { oneofKind: "addReaction", addReaction: { updates: [] } }
    }
    if (method === Method.DELETE_REACTION) {
      return { oneofKind: "deleteReaction", deleteReaction: { updates: [] } }
    }
    if (method === Method.PIN_MESSAGE) {
      return { oneofKind: "pinMessage", pinMessage: { updates: [] } }
    }
    return { oneofKind: undefined }
  }

  private record(method: string, params?: unknown) {
    this.calls.push(safeJson({ method, ...(params !== undefined ? { params } : {}) }))
  }
}

function binarySize(value: InlineSdkUploadFileParams["file"]): number | null {
  if (value instanceof Uint8Array) return value.byteLength
  if (value instanceof ArrayBuffer || value instanceof SharedArrayBuffer) return value.byteLength
  if (value instanceof Blob) return value.size
  return null
}

function chatIdFromInputPeer(peer: unknown): bigint | null {
  const inputPeer = asOptionalRecord(peer)
  const type = asOptionalRecord(inputPeer?.type)
  if (type?.oneofKind !== "chat") return null
  const chat = asOptionalRecord(type.chat)
  const chatId = chat?.chatId
  if (chatId == null) return null
  try {
    return BigInt(String(chatId))
  } catch {
    return null
  }
}

function methodName(method: Method): string {
  return Method[method] ?? String(method)
}

const client: SidecarClient = createClient(clientOptions)
const userDirectory = new InlineUserDirectory(client, {
  onError: (operation, error) => {
    console.error(`inline-sidecar: ${operation} sender hydration failed: ${redactError(error)}`)
  },
})

void connectClientLoop()
void consumeEvents()

const server = http.createServer((req, res) => {
  void handleRequest(req, res).catch((error) => {
    const err = normalizeError(error, redactError)
    writeJson(res, err.status, {
      ok: false,
      error: err.message,
      errorKind: err.errorKind,
    })
  })
})

server.listen(port, bind, () => {
  console.error(`inline-sidecar: listening on ${bind}:${port}`)
})

setupShutdown()

function attachConsumer(res: ServerResponse) {
  if (consumer) {
    consumer.end()
    consumer = null
  }
  res.writeHead(200, {
    "content-type": "application/x-ndjson; charset=utf-8",
    "cache-control": "no-cache",
    connection: "keep-alive",
  })
  consumer = res
  const waiters = consumerWaiters
  consumerWaiters = []
  for (const resolve of waiters) resolve()
  res.on("close", () => {
    if (consumer === res) consumer = null
  })
}

async function deliver(event: Json) {
  while (!stopping) {
    if (!consumer) {
      await new Promise<void>((resolve) => consumerWaiters.push(resolve))
      continue
    }
    try {
      const ok = consumer.write(JSON.stringify(event) + "\n")
      if (!ok) await once(consumer, "drain")
      return
    } catch {
      consumer = null
    }
  }
}

function inputPeerFromTarget(target: Target) {
  if ("chatId" in target) {
    return InputPeer.create({ type: { oneofKind: "chat", chat: { chatId: target.chatId } } })
  }
  return InputPeer.create({ type: { oneofKind: "user", user: { userId: target.userId } } })
}

function parseSendMedia(value: unknown): InlineSdkSendMessageMedia | undefined {
  const media = asOptionalRecord(value)
  if (!media) return undefined
  const kind = readRequiredString(media, "kind")
  if (kind === "photo") return { kind, photoId: readRequiredInlineId(media, "photoId") }
  if (kind === "video") return { kind, videoId: readRequiredInlineId(media, "videoId") }
  if (kind === "document") return { kind, documentId: readRequiredInlineId(media, "documentId") }
  throw new SidecarError(`unsupported media kind: ${kind}`, "bad_format")
}

function parseActions(value: unknown): MessageActions | undefined {
  if (value == null) return undefined
  const input = asRecord(value)
  const rows = Array.isArray(input.rows) ? input.rows : []
  return MessageActions.create({
    rows: rows.map((row) => {
      const rowRecord = asRecord(row)
      const actions = Array.isArray(rowRecord.actions) ? rowRecord.actions : []
      return MessageActionRow.create({
        actions: actions.map(parseAction),
      })
    }),
  })
}

function parseAction(value: unknown) {
  const input = asRecord(value)
  const id = readRequiredString(input, "id")
  const text = readRequiredString(input, "text")
  const callback = readOptionalString(input, "callback")
  const copyText = readOptionalString(input, "copyText")
  return MessageAction.create({
    actionId: id,
    text,
    action: callback != null
      ? {
          oneofKind: "callback",
          callback: MessageActionCallback.create({
            data: Buffer.from(callback, "utf8"),
          }),
        }
      : {
          oneofKind: "copyText",
          copyText: MessageActionCopyText.create({ text: copyText ?? text }),
        },
  })
}

function authorized(req: IncomingMessage): boolean {
  const header = req.headers["x-hermes-sidecar-token"]
  if (typeof header !== "string") return false
  return tokenEquals(header, sidecarToken)
}

function tokenEquals(actual: string, expected: string): boolean {
  const actualBuffer = Buffer.from(actual)
  const expectedBuffer = Buffer.from(expected)
  if (actualBuffer.length !== expectedBuffer.length) return false
  return timingSafeEqual(actualBuffer, expectedBuffer)
}

async function readJsonBody(req: IncomingMessage): Promise<unknown> {
  const chunks: Buffer[] = []
  let size = 0
  for await (const chunk of req) {
    const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk)
    size += buffer.length
    if (size > 5 * 1024 * 1024) throw new SidecarError("request body too large", "bad_format")
    chunks.push(buffer)
  }
  if (chunks.length === 0) return {}
  try {
    return JSON.parse(Buffer.concat(chunks).toString("utf8")) as unknown
  } catch {
    throw new SidecarError("invalid JSON request body", "bad_format")
  }
}

function writeJson(res: ServerResponse, status: number, body: unknown) {
  res.writeHead(status, { "content-type": "application/json; charset=utf-8" })
  res.end(JSON.stringify(safeJson(body)))
}

function redactError(error: unknown): string {
  return redactText(error, [
    { value: token, label: "[INLINE_TOKEN]" },
    { value: sidecarToken, label: "[INLINE_SIDECAR_TOKEN]" },
  ])
}

function log(level: string, args: unknown[]) {
  const message = args.map((arg) => typeof arg === "string" ? arg : JSON.stringify(safeJson(arg))).join(" ")
  console.error(`inline-sidecar:${level}: ${redactError(message)}`)
}

function clampRetryMs(value: number | undefined, fallback: number): number {
  if (value == null) return fallback
  return Math.min(Math.max(value, 100), 60_000)
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

async function packageVersion(): Promise<string> {
  const candidates = [
    new URL("../../../package.json", import.meta.url),
    new URL("../../package.json", import.meta.url),
  ]
  for (const pkgUrl of candidates) {
    try {
      const raw = await readFile(pkgUrl, "utf8")
      const parsed = JSON.parse(raw) as { version?: string }
      if (parsed.version) return parsed.version
    } catch {
      continue
    }
  }

  try {
    const raw = await readFile(new URL("../plugin.yaml", import.meta.url), "utf8")
    const match = /^version:\s*['"]?([^'"\n#]+)['"]?/m.exec(raw)
    return match?.[1]?.trim() || "0.0.0"
  } catch {
    return "0.0.0"
  }
}

function setupShutdown() {
  for (const sig of ["SIGINT", "SIGTERM"] as const) {
    process.on(sig, () => {
      void shutdown(0)
    })
  }
  if (process.env.INLINE_SIDECAR_WATCH_STDIN === "1") {
    process.stdin.resume()
    process.stdin.on("end", () => void shutdown(0))
    process.stdin.on("error", () => void shutdown(0))
  }
}

async function shutdown(code: number) {
  if (stopping) return
  stopping = true
  try {
    consumer?.end()
    consumer = null
    server.close()
    await client.close()
  } catch (error) {
    console.error(`inline-sidecar: shutdown error: ${redactError(error)}`)
  } finally {
    process.exitCode = code
    setTimeout(() => process.exit(code), 20).unref()
  }
}

process.on("uncaughtException", (error) => {
  console.error(`inline-sidecar: uncaught exception: ${redactError(error)}`)
  process.exit(1)
})

process.on("unhandledRejection", (error) => {
  console.error(`inline-sidecar: unhandled rejection: ${redactError(error)}`)
})
