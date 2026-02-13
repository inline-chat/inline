import { mkdir } from "node:fs/promises"
import path from "node:path"
import {
  createReplyPrefixOptions,
  createTypingCallbacks,
  logInboundDrop,
  resolveControlCommandGate,
  resolveMentionGatingWithBypass,
  type OpenClawConfig,
  type RuntimeEnv,
} from "openclaw/plugin-sdk"
import { InlineSdkClient, JsonFileStateStore, Method, type Message } from "@inline-chat/realtime-sdk"
import { resolveInlineToken, type ResolvedInlineAccount } from "./accounts.js"
import { resolveInlineGroupRequireMention } from "./policy.js"
import { getInlineRuntime } from "../runtime.js"
import { uploadInlineMediaFromUrl } from "./media.js"

const CHANNEL_ID = "inline" as const

type InlineMonitorHandle = {
  stop: () => Promise<void>
}

type StatusSink = (patch: { lastInboundAt?: number; lastOutboundAt?: number; lastError?: string }) => void

type CachedChatInfo = {
  kind: "direct" | "group"
  title: string | null
}

type SenderProfile = {
  name?: string
  username?: string
}

type HistoryContext = {
  historyText: string | null
  repliedToBot: boolean
  replyToSenderId: string | null
}

const DEFAULT_GROUP_HISTORY_LIMIT = 12
const DEFAULT_DM_HISTORY_LIMIT = 6
const HISTORY_LINE_MAX_CHARS = 280
const BOT_MESSAGE_CACHE_LIMIT = 500
const REACTION_TARGET_LOOKUP_LIMIT = 8
const REPLY_TARGET_LOOKUP_LIMIT = 8

function normalizeAllowEntry(raw: string): string {
  return raw.trim().replace(/^inline:/i, "").replace(/^user:/i, "")
}

function normalizeAllowlist(entries: Array<string | number> | undefined): string[] {
  return (entries ?? [])
    .map((entry) => normalizeAllowEntry(String(entry)))
    .map((entry) => entry.trim())
    .filter(Boolean)
}

function allowlistMatch(params: { allowFrom: string[]; senderId: string }): boolean {
  if (params.allowFrom.some((entry) => entry === "*")) return true
  return params.allowFrom.some((entry) => entry === params.senderId)
}

async function resolveChatInfo(
  client: InlineSdkClient,
  cache: Map<bigint, CachedChatInfo>,
  chatId: bigint,
): Promise<CachedChatInfo> {
  const existing = cache.get(chatId)
  if (existing) return existing

  const result = await client.getChat({ chatId })
  const peerKind = result.peer?.type.oneofKind
  const kind: CachedChatInfo["kind"] = peerKind === "user" ? "direct" : "group"
  const title = result.title?.trim() || null
  const info: CachedChatInfo = { kind, title }
  cache.set(chatId, info)
  return info
}

function messageText(message: Message): string {
  return (message.message ?? "").trim()
}

function normalizeInlineUsername(raw: string | undefined): string | undefined {
  const trimmed = raw?.trim()
  if (!trimmed) return undefined
  return trimmed.startsWith("@") ? trimmed.slice(1) : trimmed
}

function buildInlineSenderName(params: {
  firstName: string | undefined
  lastName: string | undefined
}): string | undefined {
  const name = [params.firstName, params.lastName].filter(Boolean).join(" ").trim()
  return name || undefined
}

function rewriteNumericMentionsToUsernames(text: string, senderProfilesById: Map<string, SenderProfile>): string {
  if (!text.includes("@")) return text
  return text.replace(/(^|[^\w])@([0-9]+)\b/g, (full, prefix: string, userId: string) => {
    const username = senderProfilesById.get(userId)?.username
    if (!username) return full
    return `${prefix}@${username}`
  })
}

function rememberBotMessageId(cache: Map<string, string[]>, chatId: bigint, messageId: bigint): void {
  const key = String(chatId)
  const list = cache.get(key) ?? []
  const nextId = String(messageId)
  if (!list.includes(nextId)) list.push(nextId)
  if (list.length > BOT_MESSAGE_CACHE_LIMIT) {
    list.splice(0, list.length - BOT_MESSAGE_CACHE_LIMIT)
  }
  cache.set(key, list)
}

function hasBotMessageId(cache: Map<string, string[]>, chatId: bigint, messageId: bigint): boolean {
  const key = String(chatId)
  return (cache.get(key) ?? []).includes(String(messageId))
}

function rememberBotMessagesFromList(params: {
  messages: Message[]
  meId: bigint
  chatId: bigint
  botMessageIdsByChat: Map<string, string[]>
}): void {
  for (const item of params.messages) {
    if (item.fromId === params.meId) {
      rememberBotMessageId(params.botMessageIdsByChat, params.chatId, item.id)
    }
  }
}

function buildChatPeer(chatId: bigint): {
  type: {
    oneofKind: "chat"
    chat: { chatId: bigint }
  }
} {
  return {
    type: {
      oneofKind: "chat",
      chat: { chatId },
    },
  }
}

async function loadChatHistoryMessages(params: {
  client: InlineSdkClient
  chatId: bigint
  limit: number
  offsetId?: bigint
}): Promise<Message[] | null> {
  const result = await params.client.invokeRaw(Method.GET_CHAT_HISTORY, {
    oneofKind: "getChatHistory",
    getChatHistory: {
      peerId: buildChatPeer(params.chatId),
      ...(params.offsetId != null ? { offsetId: params.offsetId } : {}),
      limit: params.limit,
    },
  })
  if (result.oneofKind !== "getChatHistory") {
    return null
  }
  return result.getChatHistory.messages ?? []
}

async function findChatMessageById(params: {
  client: InlineSdkClient
  chatId: bigint
  messageId: bigint
  limit: number
  meId: bigint
  botMessageIdsByChat: Map<string, string[]>
}): Promise<Message | null> {
  const directResult = await params.client
    .invokeRaw(Method.GET_MESSAGES, {
      oneofKind: "getMessages",
      getMessages: {
        peerId: buildChatPeer(params.chatId),
        messageIds: [params.messageId],
      },
    })
    .catch(() => null)
  if (directResult?.oneofKind === "getMessages") {
    const directMessages = directResult.getMessages.messages ?? []
    rememberBotMessagesFromList({
      messages: directMessages,
      meId: params.meId,
      chatId: params.chatId,
      botMessageIdsByChat: params.botMessageIdsByChat,
    })
    const directTarget = directMessages.find((item) => item.id === params.messageId) ?? null
    if (directTarget) {
      return directTarget
    }
  }

  // Compatibility fallback for older servers without GET_MESSAGES.
  const historyMessages = await loadChatHistoryMessages({
    client: params.client,
    chatId: params.chatId,
    offsetId: params.messageId + 1n,
    limit: params.limit,
  })
  if (!historyMessages) {
    return null
  }

  rememberBotMessagesFromList({
    messages: historyMessages,
    meId: params.meId,
    chatId: params.chatId,
    botMessageIdsByChat: params.botMessageIdsByChat,
  })

  return historyMessages.find((item) => item.id === params.messageId) ?? null
}

async function isReactionTargetBotMessage(params: {
  client: InlineSdkClient
  chatId: bigint
  messageId: bigint
  meId: bigint
  botMessageIdsByChat: Map<string, string[]>
}): Promise<boolean> {
  const target = await findChatMessageById({
    client: params.client,
    chatId: params.chatId,
    messageId: params.messageId,
    limit: REACTION_TARGET_LOOKUP_LIMIT,
    meId: params.meId,
    botMessageIdsByChat: params.botMessageIdsByChat,
  })
  if (!target) {
    return hasBotMessageId(params.botMessageIdsByChat, params.chatId, params.messageId)
  }
  return target.fromId === params.meId
}

function normalizeHistoryText(raw: string | undefined): string {
  const compact = (raw ?? "").replace(/\s+/g, " ").trim()
  if (!compact) return ""
  if (compact.length <= HISTORY_LINE_MAX_CHARS) return compact
  return `${compact.slice(0, HISTORY_LINE_MAX_CHARS - 1)}…`
}

function resolveHistorySenderLabel(params: {
  senderId: bigint
  meId: bigint
  senderProfilesById: Map<string, SenderProfile>
}): string {
  if (params.senderId === params.meId) return "assistant"
  const senderId = String(params.senderId)
  const profile = params.senderProfilesById.get(senderId)
  if (profile?.username) return `@${profile.username}`
  if (profile?.name) return profile.name
  return `user:${senderId}`
}

function resolveHistoryLimit(params: {
  isGroup: boolean
  historyLimit: number | undefined
  dmHistoryLimit: number | undefined
}): number {
  if (params.isGroup) {
    return params.historyLimit ?? DEFAULT_GROUP_HISTORY_LIMIT
  }
  return params.dmHistoryLimit ?? params.historyLimit ?? DEFAULT_DM_HISTORY_LIMIT
}

async function buildHistoryContext(params: {
  client: InlineSdkClient
  chatId: bigint
  currentMessageId: bigint
  replyToMsgId: bigint | undefined
  senderProfilesById: Map<string, SenderProfile>
  meId: bigint
  historyLimit: number
  botMessageIdsByChat: Map<string, string[]>
}): Promise<HistoryContext> {
  const cachedReplyToBot =
    params.replyToMsgId != null &&
    hasBotMessageId(params.botMessageIdsByChat, params.chatId, params.replyToMsgId)
  let repliedToBot = cachedReplyToBot
  let replyToSenderId: string | null = null
  let foundReplyTargetInHistory = false
  const lines: string[] = []

  if (params.historyLimit > 0) {
    const messages = await loadChatHistoryMessages({
      client: params.client,
      chatId: params.chatId,
      offsetId: params.currentMessageId,
      limit: params.historyLimit,
    })

    if (messages) {
      for (const item of messages) {
        if (item.fromId === params.meId) {
          rememberBotMessageId(params.botMessageIdsByChat, params.chatId, item.id)
        }
      }

      const sortedMessages = messages
        .filter((item) => item.id !== params.currentMessageId)
        .sort((a, b) => {
          const byDate = Number(a.date - b.date)
          if (byDate !== 0) return byDate
          if (a.id === b.id) return 0
          return a.id < b.id ? -1 : 1
        })

      for (const item of sortedMessages) {
        if (params.replyToMsgId != null && item.id === params.replyToMsgId) {
          foundReplyTargetInHistory = true
          replyToSenderId = String(item.fromId)
          repliedToBot = item.fromId === params.meId
        }

        const text = normalizeHistoryText(item.message)
        if (!text) continue
        const label = resolveHistorySenderLabel({
          senderId: item.fromId,
          meId: params.meId,
          senderProfilesById: params.senderProfilesById,
        })
        const replySuffix = item.replyToMsgId != null ? ` ->${String(item.replyToMsgId)}` : ""
        lines.push(`#${String(item.id)}${replySuffix} ${label}: ${text}`)
      }
    }
  }

  if (params.replyToMsgId != null && !foundReplyTargetInHistory) {
    const replyTarget = await findChatMessageById({
      client: params.client,
      chatId: params.chatId,
      messageId: params.replyToMsgId,
      limit: REPLY_TARGET_LOOKUP_LIMIT,
      meId: params.meId,
      botMessageIdsByChat: params.botMessageIdsByChat,
    })
    if (replyTarget) {
      replyToSenderId = String(replyTarget.fromId)
      repliedToBot = replyTarget.fromId === params.meId
    } else if (!cachedReplyToBot) {
      repliedToBot = false
    }
  }

  if (!lines.length) {
    return { historyText: null, repliedToBot, replyToSenderId }
  }
  return {
    historyText: `Recent thread messages (oldest -> newest):\n${lines.join("\n")}`,
    repliedToBot,
    replyToSenderId,
  }
}

export async function monitorInlineProvider(params: {
  cfg: OpenClawConfig
  account: ResolvedInlineAccount
  runtime: RuntimeEnv
  abortSignal: AbortSignal
  log?: { info: (msg: string) => void; warn: (msg: string) => void; error: (msg: string) => void; debug?: (msg: string) => void }
  statusSink?: StatusSink
}): Promise<InlineMonitorHandle> {
  const { cfg, account, runtime, abortSignal, log, statusSink } = params
  const core = getInlineRuntime()

  if (!account.configured || !account.baseUrl) {
    throw new Error(`Inline not configured for account "${account.accountId}" (missing baseUrl or token)`)
  }
  const token = await resolveInlineToken(account)

  const stateDir = core.state.resolveStateDir()
  const statePath = path.join(stateDir, "channels", "inline", `${account.accountId}.json`)
  await mkdir(path.dirname(statePath), { recursive: true })

  const sdkLog = {
    debug: (msg: string) => log?.debug?.(msg),
    info: (msg: string) => log?.info(msg),
    warn: (msg: string) => log?.warn(msg),
    error: (msg: string) => log?.error(msg),
  }

  const client = new InlineSdkClient({
    baseUrl: account.baseUrl,
    token,
    logger: sdkLog,
    state: new JsonFileStateStore(statePath),
  })

  await client.connect(abortSignal)
  const me = await client.getMe()
  log?.info(`[${account.accountId}] inline connected (me=${String(me.userId)})`)

  const chatCache = new Map<bigint, CachedChatInfo>()
  const senderProfilesById = new Map<string, SenderProfile>()
  const botMessageIdsByChat = new Map<string, string[]>()
  const hydratedParticipantChats = new Set<string>()
  const participantFetches = new Map<string, Promise<void>>()

  const hydrateChatParticipants = async (chatId: bigint): Promise<void> => {
    const chatKey = String(chatId)
    if (hydratedParticipantChats.has(chatKey)) return
    const existing = participantFetches.get(chatKey)
    if (existing) return existing

    const run = (async () => {
      const result = await client.invokeRaw(Method.GET_CHAT_PARTICIPANTS, {
        oneofKind: "getChatParticipants",
        getChatParticipants: { chatId },
      })
      if (result.oneofKind !== "getChatParticipants") return

      for (const user of result.getChatParticipants.users ?? []) {
        const userId = String(user.id)
        if (!userId) continue
        const nextName = buildInlineSenderName({ firstName: user.firstName, lastName: user.lastName })
        const nextUsername = normalizeInlineUsername(user.username)
        const previous = senderProfilesById.get(userId)
        const mergedName = nextName ?? previous?.name
        const mergedUsername = nextUsername ?? previous?.username
        senderProfilesById.set(userId, {
          ...(mergedName ? { name: mergedName } : {}),
          ...(mergedUsername ? { username: mergedUsername } : {}),
        })
      }

      hydratedParticipantChats.add(chatKey)
    })()
      .catch((err) => {
        statusSink?.({ lastError: `getChatParticipants failed: ${String(err)}` })
      })
      .finally(() => {
        participantFetches.delete(chatKey)
      })

    participantFetches.set(chatKey, run)
    await run
  }

  const loop = (async () => {
    try {
      for await (const event of client.events()) {
        if (abortSignal.aborted) break
        let msg: Message
        let rawBody = ""
        let reactionEvent: { action: "added" | "removed"; emoji: string; targetMessageId: bigint } | null = null

        if (event.kind === "message.new") {
          msg = event.message
          rawBody = messageText(msg)
          if (!rawBody) continue

          // Ignore echoes / our own outbound messages.
          if (msg.out || msg.fromId === me.userId) continue
        } else if (event.kind === "reaction.add") {
          if (event.reaction.userId === me.userId) continue
          const onBotMessage = await isReactionTargetBotMessage({
            client,
            chatId: event.chatId,
            messageId: event.reaction.messageId,
            meId: me.userId,
            botMessageIdsByChat,
          }).catch((err) => {
            statusSink?.({ lastError: `getChatHistory (reaction target) failed: ${String(err)}` })
            return false
          })
          if (!onBotMessage) continue

          reactionEvent = {
            action: "added",
            emoji: event.reaction.emoji,
            targetMessageId: event.reaction.messageId,
          }
          msg = {
            id: event.reaction.messageId,
            chatId: event.chatId,
            date: event.date,
            fromId: event.reaction.userId,
            message: "",
            out: false,
            mentioned: false,
            replyToMsgId: event.reaction.messageId,
          } as Message
        } else if (event.kind === "reaction.delete") {
          if (event.userId === me.userId) continue
          const onBotMessage = await isReactionTargetBotMessage({
            client,
            chatId: event.chatId,
            messageId: event.messageId,
            meId: me.userId,
            botMessageIdsByChat,
          }).catch((err) => {
            statusSink?.({ lastError: `getChatHistory (reaction target) failed: ${String(err)}` })
            return false
          })
          if (!onBotMessage) continue

          reactionEvent = {
            action: "removed",
            emoji: event.emoji,
            targetMessageId: event.messageId,
          }
          msg = {
            id: event.messageId,
            chatId: event.chatId,
            date: event.date,
            fromId: event.userId,
            message: "",
            out: false,
            mentioned: false,
            replyToMsgId: event.messageId,
          } as Message
        } else {
          continue
        }

        const chatId = event.chatId
        statusSink?.({ lastInboundAt: Date.now() })

        let chatInfo: CachedChatInfo
        try {
          chatInfo = await resolveChatInfo(client, chatCache, chatId)
        } catch (err) {
          // Default conservative behavior if metadata fetch fails.
          chatInfo = { kind: "group", title: null }
          statusSink?.({ lastError: `getChat failed: ${String(err)}` })
        }

        const isGroup = chatInfo.kind !== "direct"
        const senderId = String(msg.fromId)
        await hydrateChatParticipants(chatId)
        const senderProfile = senderProfilesById.get(senderId)
        const senderUsername = senderProfile?.username
        const senderName = senderProfile?.name ?? (!isGroup ? chatInfo.title ?? undefined : undefined)
        if (reactionEvent) {
          const actor =
            senderUsername != null && senderUsername.length > 0
              ? `@${senderUsername}`
              : senderName ?? `user:${senderId}`
          const emoji = reactionEvent.emoji.trim() || "a reaction"
          const messageId = String(reactionEvent.targetMessageId)
          if (reactionEvent.action === "added") {
            rawBody = `${actor} reacted with ${emoji} to your message #${messageId}`
          } else {
            rawBody = `${actor} removed ${emoji} from your message #${messageId}`
          }
        }

        const dmPolicy = account.config.dmPolicy ?? "pairing"
        const defaultGroupPolicy = cfg.channels?.defaults?.groupPolicy
        const groupPolicy = account.config.groupPolicy ?? defaultGroupPolicy ?? "allowlist"

        const configAllowFrom = normalizeAllowlist(account.config.allowFrom)
        const configGroupAllowFrom = normalizeAllowlist(account.config.groupAllowFrom)
        const storeAllowFrom = await core.channel.pairing.readAllowFromStore(CHANNEL_ID).catch(() => [])
        const storeAllowList = normalizeAllowlist(storeAllowFrom)

        const effectiveAllowFrom = [...configAllowFrom, ...storeAllowList].filter(Boolean)
        const effectiveGroupAllowFrom = [
          ...(configGroupAllowFrom.length > 0 ? configGroupAllowFrom : configAllowFrom),
          ...storeAllowList,
        ].filter(Boolean)

        const allowTextCommands = core.channel.commands.shouldHandleTextCommands({
          cfg,
          surface: CHANNEL_ID,
        })
        const useAccessGroups = cfg.commands?.useAccessGroups !== false
        const allowForCommands = isGroup ? effectiveGroupAllowFrom : effectiveAllowFrom
        const senderAllowedForCommands = allowlistMatch({ allowFrom: allowForCommands, senderId })
        const hasControlCommand = core.channel.text.hasControlCommand(rawBody, cfg)
        const commandGate = resolveControlCommandGate({
          useAccessGroups,
          authorizers: [{ configured: allowForCommands.length > 0, allowed: senderAllowedForCommands }],
          allowTextCommands,
          hasControlCommand,
        })
        const commandAuthorized = commandGate.commandAuthorized

        if (isGroup) {
          if (groupPolicy === "disabled") {
            log?.info(
              `[${account.accountId}] inline: drop group chat=${String(chatId)} (groupPolicy=disabled)`,
            )
            continue
          }
          if (groupPolicy === "allowlist") {
            const allowed = allowlistMatch({ allowFrom: effectiveGroupAllowFrom, senderId })
            if (!allowed) {
              log?.info(`[${account.accountId}] inline: drop group sender=${senderId} (groupPolicy=allowlist)`)
              continue
            }
          }
        } else {
          if (dmPolicy === "disabled") {
            log?.info(`[${account.accountId}] inline: drop DM sender=${senderId} (dmPolicy=disabled)`)
            continue
          }
          if (dmPolicy !== "open") {
            const allowed = allowlistMatch({ allowFrom: effectiveAllowFrom, senderId })
            if (!allowed) {
              if (dmPolicy === "pairing") {
                const { code, created } = await core.channel.pairing.upsertPairingRequest({
                  channel: CHANNEL_ID,
                  id: senderId,
                  meta: {},
                  // Pass adapter explicitly to avoid relying on registry lookup for plugin channels.
                  pairingAdapter: { idLabel: "inlineUserId", normalizeAllowEntry },
                })
                if (created) {
                  try {
                    await client.sendMessage({
                      chatId,
                      text: core.channel.pairing.buildPairingReply({
                        channel: CHANNEL_ID,
                        idLine: `Your Inline user id: ${senderId}`,
                        code,
                      }),
                    })
                    statusSink?.({ lastOutboundAt: Date.now() })
                  } catch (err) {
                    runtime.error?.(`inline: pairing reply failed for ${senderId}: ${String(err)}`)
                  }
                }
              }
              log?.info(`[${account.accountId}] inline: drop DM sender=${senderId} (dmPolicy=${dmPolicy})`)
              continue
            }
          }
        }

        if (commandGate.shouldBlock) {
          logInboundDrop({
            log: (m) => runtime.log?.(m),
            channel: CHANNEL_ID,
            reason: "control command (unauthorized)",
            target: senderId,
          })
          continue
        }

        const route = core.channel.routing.resolveAgentRoute({
          cfg,
          channel: CHANNEL_ID,
          accountId: account.accountId,
          peer: {
            kind: isGroup ? "group" : "direct",
            // DM sessions should be stable per sender. Group sessions should be stable per chat.
            id: isGroup ? String(chatId) : senderId,
          },
        })

        const mentionRegexes = core.channel.mentions.buildMentionRegexes(cfg, route.agentId)
        const wasMentioned =
          typeof msg.mentioned === "boolean"
            ? msg.mentioned
            : mentionRegexes.length
              ? core.channel.mentions.matchesMentionPatterns(rawBody, mentionRegexes)
              : false
        const historyLimit = resolveHistoryLimit({
          isGroup,
          historyLimit: account.config.historyLimit,
          dmHistoryLimit: account.config.dmHistoryLimit,
        })
        const historyContext = await buildHistoryContext({
          client,
          chatId,
          currentMessageId: msg.id,
          replyToMsgId: msg.replyToMsgId,
          senderProfilesById,
          meId: me.userId,
          historyLimit,
          botMessageIdsByChat,
        }).catch((err) => {
          statusSink?.({ lastError: `getChatHistory failed: ${String(err)}` })
          return { historyText: null, repliedToBot: false, replyToSenderId: null }
        })
        const implicitMention =
          (reactionEvent != null && isGroup) ||
          (isGroup &&
            (account.config.replyToBotWithoutMention ?? false) &&
            msg.replyToMsgId != null &&
            historyContext.repliedToBot)

        const requireMention = isGroup
          ? resolveInlineGroupRequireMention({
              cfg,
              groupId: String(chatId),
              accountId: account.accountId,
              requireMentionDefault: account.config.requireMention ?? false,
            })
          : false
        const mentionGate = resolveMentionGatingWithBypass({
          isGroup,
          requireMention,
          canDetectMention: typeof msg.mentioned === "boolean" || mentionRegexes.length > 0,
          wasMentioned,
          implicitMention,
          allowTextCommands,
          hasControlCommand,
          commandAuthorized,
        })
        if (isGroup && mentionGate.shouldSkip) {
          runtime.log?.(`inline: drop group chat ${String(chatId)} (no mention)`)
          continue
        }

        const timestamp = Number(msg.date) * 1000
        const fromLabel = isGroup ? `chat:${chatInfo.title ?? String(chatId)}` : `user:${senderId}`

        const storePath = core.channel.session.resolveStorePath(cfg.session?.store, { agentId: route.agentId })
        const envelopeOptions = core.channel.reply.resolveEnvelopeFormatOptions(cfg)
        const previousTimestamp = core.channel.session.readSessionUpdatedAt({ storePath, sessionKey: route.sessionKey })
        const body = core.channel.reply.formatAgentEnvelope({
          channel: "Inline",
          from: fromLabel,
          timestamp,
          ...(previousTimestamp != null ? { previousTimestamp } : {}),
          envelope: envelopeOptions,
          body: historyContext.historyText
            ? `${historyContext.historyText}\n\nCurrent message:\n${rawBody}`
            : rawBody,
        })

        const ctxPayload = core.channel.reply.finalizeInboundContext({
          Body: body,
          RawBody: rawBody,
          CommandBody: rawBody,
          From: isGroup ? `inline:chat:${String(chatId)}` : `inline:${senderId}`,
          To: `inline:${String(chatId)}`,
          SessionKey: route.sessionKey,
          AccountId: route.accountId,
          ChatType: isGroup ? "group" : "direct",
          ConversationLabel: fromLabel,
          ...(isGroup ? { GroupSubject: chatInfo.title ?? String(chatId) } : {}),
          SenderId: senderId,
          ...(senderName ? { SenderName: senderName } : {}),
          ...(senderUsername ? { SenderUsername: senderUsername } : {}),
          Provider: CHANNEL_ID,
          Surface: CHANNEL_ID,
          MessageSid: String(msg.id),
          ...(msg.replyToMsgId != null ? { ReplyToId: String(msg.replyToMsgId) } : {}),
          ...(historyContext.replyToSenderId != null ? { ReplyToSenderId: historyContext.replyToSenderId } : {}),
          ...(msg.replyToMsgId != null ? { ReplyToWasBot: historyContext.repliedToBot } : {}),
          Timestamp: timestamp || Date.now(),
          WasMentioned: mentionGate.effectiveWasMentioned,
          CommandAuthorized: commandAuthorized,
          OriginatingChannel: CHANNEL_ID,
          OriginatingTo: `inline:${String(chatId)}`,
        })

        await core.channel.session.recordInboundSession({
          storePath,
          sessionKey: ctxPayload.SessionKey ?? route.sessionKey,
          ctx: ctxPayload,
          ...(!isGroup
            ? {
                updateLastRoute: {
                  sessionKey: route.mainSessionKey,
                  channel: CHANNEL_ID,
                  to: `inline:${String(chatId)}`,
                  accountId: route.accountId,
                },
              }
            : {}),
          onRecordError: (err) => runtime.error?.(`inline: failed updating session meta: ${String(err)}`),
        })

        const prefixConfig = (
          typeof createReplyPrefixOptions === "function"
            ? createReplyPrefixOptions({
                cfg,
                agentId: route.agentId,
                channel: CHANNEL_ID,
                accountId: account.accountId,
              })
            : {}
        ) as { onModelSelected?: unknown } & Record<string, unknown>
        const onModelSelected =
          typeof prefixConfig.onModelSelected === "function"
            ? (prefixConfig.onModelSelected as (ctx: unknown) => void)
            : undefined
        const { onModelSelected: _ignoredOnModelSelected, ...prefixOptions } = prefixConfig

        const typingCallbacks =
          typeof createTypingCallbacks === "function"
            ? createTypingCallbacks({
                start: () => client.sendTyping({ chatId, typing: true }),
                stop: () => client.sendTyping({ chatId, typing: false }),
                onStartError: (err) => runtime.error?.(`inline typing start failed: ${String(err)}`),
                onStopError: (err) => runtime.error?.(`inline typing stop failed: ${String(err)}`),
              })
            : {}

        const parseMarkdown = account.config.parseMarkdown ?? true
        const disableBlockStreaming =
          typeof account.config.blockStreaming === "boolean"
            ? !account.config.blockStreaming
            : undefined
        const replyOptions = {
          ...(onModelSelected ? { onModelSelected } : {}),
          blockReplyTimeoutMs: 25_000,
          ...(typeof disableBlockStreaming === "boolean" ? { disableBlockStreaming } : {}),
        }

        await core.channel.reply.dispatchReplyWithBufferedBlockDispatcher({
          ctx: ctxPayload,
          cfg,
          dispatcherOptions: {
            ...prefixOptions,
            ...typingCallbacks,
            deliver: async (payload) => {
              const rawText = (payload.text ?? "").trim()
              const mediaList = payload.mediaUrls?.length
                ? payload.mediaUrls
                : payload.mediaUrl
                  ? [payload.mediaUrl]
                  : []
              const outboundText = rewriteNumericMentionsToUsernames(rawText, senderProfilesById)

              let replyToMsgId: bigint | undefined
              if (payload.replyToId != null) {
                try {
                  replyToMsgId = BigInt(payload.replyToId)
                } catch {
                  // ignore
                }
              }
              // Keep reply chains threaded when inbound is a reply in group chats.
              if (replyToMsgId == null && isGroup && msg.replyToMsgId != null) {
                replyToMsgId = msg.id
              }

              const rememberSent = (messageId: bigint | null) => {
                if (messageId != null) {
                  rememberBotMessageId(botMessageIdsByChat, chatId, messageId)
                }
              }

              const sendTextFallback = async (text: string, includeReplyTo: boolean): Promise<void> => {
                if (!text.trim()) return
                const sent = await client.sendMessage({
                  chatId,
                  text,
                  ...(includeReplyTo && replyToMsgId != null ? { replyToMsgId } : {}),
                  parseMarkdown,
                })
                rememberSent(sent.messageId)
              }

              if (mediaList.length === 0) {
                if (!outboundText.trim()) return
                await sendTextFallback(outboundText, true)
                statusSink?.({ lastOutboundAt: Date.now() })
                return
              }

              for (let index = 0; index < mediaList.length; index++) {
                const mediaUrl = mediaList[index]
                if (!mediaUrl?.trim()) continue
                const isFirst = index === 0
                const caption = isFirst ? outboundText : ""
                try {
                  const media = await uploadInlineMediaFromUrl({
                    client,
                    cfg,
                    accountId: account.accountId,
                    mediaUrl,
                  })
                  const sent = await client.sendMessage({
                    chatId,
                    ...(caption ? { text: caption } : {}),
                    media,
                    ...(isFirst && replyToMsgId != null ? { replyToMsgId } : {}),
                    ...(caption ? { parseMarkdown } : {}),
                  })
                  rememberSent(sent.messageId)
                } catch (error) {
                  runtime.error?.(`inline media upload failed; falling back to url text (${String(error)})`)
                  const fallbackText = caption
                    ? `${caption}\n\nAttachment: ${mediaUrl}`
                    : `Attachment: ${mediaUrl}`
                  await sendTextFallback(fallbackText, isFirst)
                }
              }

              statusSink?.({ lastOutboundAt: Date.now() })
            },
            onError: (err, info) => runtime.error?.(`inline ${info.kind} reply failed: ${String(err)}`),
          },
          replyOptions,
        })
      }
    } catch (err) {
      statusSink?.({ lastError: String(err) })
      runtime.error?.(`inline monitor loop crashed: ${String(err)}`)
    }
  })()

  const stop = async () => {
    await client.close().catch(() => {})
    await loop.catch(() => {})
  }

  abortSignal.addEventListener(
    "abort",
    () => {
      void stop()
    },
    { once: true },
  )

  return { stop }
}
