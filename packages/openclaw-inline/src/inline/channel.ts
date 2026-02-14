import {
  buildChannelConfigSchema,
  DEFAULT_ACCOUNT_ID,
  formatPairingApproveHint,
  PAIRING_APPROVED_MESSAGE,
  type ChannelPlugin,
  type OpenClawConfig,
} from "openclaw/plugin-sdk"
import { InlineSdkClient, Method, type Chat, type Dialog, type User } from "@inline-chat/realtime-sdk"
import { InlineConfigSchema } from "./config-schema.js"
import {
  listInlineAccountIds,
  resolveDefaultInlineAccountId,
  resolveInlineAccount,
  resolveInlineToken,
  type ResolvedInlineAccount,
} from "./accounts.js"
import { looksLikeInlineTargetId, normalizeInlineTarget } from "./normalize.js"
import { monitorInlineProvider } from "./monitor.js"
import { resolveInlineGroupRequireMention, resolveInlineGroupToolPolicy } from "./policy.js"
import { inlineMessageActions } from "./actions.js"
import { getInlineRuntime } from "../runtime.js"
import { uploadInlineMediaFromUrl } from "./media.js"

const activeMonitors = new Map<string, { stop: () => Promise<void> }>()

const meta = {
  id: "inline",
  label: "Inline",
  selectionLabel: "Inline (native)",
  docsPath: "/channels/inline",
  docsLabel: "inline",
  blurb: "Inline Chat via realtime RPC (bot token).",
  aliases: ["inline-chat"],
  order: 30,
  quickstartAllowFrom: true,
}

function normalizeInlineAllowEntry(raw: string): string {
  return raw.trim().replace(/^inline:/i, "").replace(/^user:/i, "")
}

function parseInlineId(raw: unknown): bigint | undefined {
  if (raw == null) return undefined
  if (typeof raw === "bigint") return raw
  if (typeof raw === "number") {
    if (!Number.isFinite(raw) || !Number.isInteger(raw) || raw < 0) return undefined
    return BigInt(raw)
  }
  if (typeof raw === "string") {
    const trimmed = raw.trim()
    if (!trimmed) return undefined
    try {
      return BigInt(trimmed)
    } catch {
      return undefined
    }
  }
  return undefined
}

function parseInlineOutboundTarget(params: {
  raw: string
  context: "sendText" | "sendMedia"
}): {
  targetId: bigint
  kind: "chat" | "user"
  normalizedNumeric: string
} {
  let normalizedTarget = params.raw.trim()
  if (/^inline:/i.test(normalizedTarget)) {
    normalizedTarget = normalizedTarget.replace(/^inline:/i, "").trim()
  }
  if (!normalizedTarget) {
    throw new Error(`inline ${params.context}: missing target`)
  }

  let kind: "chat" | "user" = "chat"
  if (/^chat:/i.test(normalizedTarget)) {
    kind = "chat"
    normalizedTarget = normalizedTarget.replace(/^chat:/i, "").trim()
  } else if (/^user:/i.test(normalizedTarget)) {
    kind = "user"
    normalizedTarget = normalizedTarget.replace(/^user:/i, "").trim()
  }
  // Keep backward compatibility for existing bare numeric ids that
  // historically mapped to chat ids.
  normalizedTarget = normalizeInlineTarget(normalizedTarget) ?? normalizedTarget

  if (!/^[0-9]+$/.test(normalizedTarget)) {
    throw new Error(
      `inline ${params.context}: invalid target "${params.raw}" (expected chat id or user id)`,
    )
  }

  return {
    targetId: BigInt(normalizedTarget),
    kind,
    normalizedNumeric: normalizedTarget,
  }
}

function buildInlineDisplayName(params: {
  firstName?: string
  lastName?: string
  username?: string
}): string {
  const explicit = [params.firstName?.trim(), params.lastName?.trim()].filter(Boolean).join(" ")
  if (explicit) return explicit
  const username = params.username?.trim()
  if (username) return `@${username}`
  return "Unknown"
}

function toInlineUserDirectoryEntry(user: User) {
  return {
    kind: "user" as const,
    id: String(user.id),
    name: buildInlineDisplayName(user),
    ...(user.username?.trim() ? { handle: `@${user.username.trim()}` } : {}),
    ...(user.profilePhoto?.cdnUrl ? { avatarUrl: user.profilePhoto.cdnUrl } : {}),
    raw: {
      username: user.username ?? null,
      phoneNumber: user.phoneNumber ?? null,
      bot: user.bot ?? false,
    },
  }
}

function toInlineGroupDirectoryEntry(chat: Chat, dialogByChatId: Map<string, Dialog>) {
  const dialog = dialogByChatId.get(String(chat.id))
  return {
    kind: "group" as const,
    id: String(chat.id),
    name: chat.title,
    raw: {
      spaceId: chat.spaceId != null ? String(chat.spaceId) : null,
      isPublic: chat.isPublic ?? false,
      unreadCount: dialog?.unreadCount ?? 0,
      archived: Boolean(dialog?.archived),
      pinned: Boolean(dialog?.pinned),
    },
  }
}

function matchesInlineQuery(value: string, query: string): boolean {
  if (!query) return true
  return value.toLowerCase().includes(query)
}

function normalizeSearchQuery(query: string | null | undefined): string {
  return query?.trim().toLowerCase() ?? ""
}

function buildDialogMap(dialogs: Dialog[]): Map<string, Dialog> {
  const map = new Map<string, Dialog>()
  for (const dialog of dialogs) {
    if (dialog.chatId != null) {
      map.set(String(dialog.chatId), dialog)
      continue
    }
    const peer = dialog.peer?.type
    if (peer?.oneofKind === "chat") {
      map.set(String(peer.chat.chatId), dialog)
    }
  }
  return map
}

async function withInlineClient<T>(params: {
  cfg: OpenClawConfig
  accountId?: string | null
  fn: (client: InlineSdkClient, account: ResolvedInlineAccount) => Promise<T>
}): Promise<T> {
  const account = resolveInlineAccount({ cfg: params.cfg, accountId: params.accountId ?? null })
  if (!account.configured || !account.baseUrl) {
    throw new Error(`Inline not configured for account "${account.accountId}" (missing token or baseUrl)`)
  }
  const token = await resolveInlineToken(account)
  const client = new InlineSdkClient({
    baseUrl: account.baseUrl,
    token,
  })
  await client.connect()
  try {
    return await params.fn(client, account)
  } finally {
    await client.close().catch(() => {})
  }
}

async function notifyPairingApprovedInline(params: {
  cfg: OpenClawConfig
  id: string
}): Promise<void> {
  const normalizedId = normalizeInlineAllowEntry(params.id)
  if (!normalizedId) return
  let userId: bigint
  try {
    userId = BigInt(normalizedId)
  } catch {
    throw new Error(`inline pairing notify: invalid user id "${params.id}"`)
  }

  const accountId = resolveDefaultInlineAccountId(params.cfg)
  const account = resolveInlineAccount({ cfg: params.cfg, accountId })
  if (!account.configured || !account.baseUrl) {
    throw new Error(`Inline not configured for account "${account.accountId}" (missing token or baseUrl)`)
  }

  const token = await resolveInlineToken(account)

  const client = new InlineSdkClient({
    baseUrl: account.baseUrl,
    token,
  })

  await client.connect()
  try {
    await client.sendMessage({
      userId,
      text: PAIRING_APPROVED_MESSAGE,
      parseMarkdown: account.config.parseMarkdown ?? true,
    })
  } finally {
    await client.close().catch(() => {})
  }
}

async function sendMessageInline(params: {
  cfg: OpenClawConfig
  to: string
  text: string
  accountId?: string | null
  replyToId?: string | null
}): Promise<{ messageId: string; chatId: string }> {
  const account = resolveInlineAccount({ cfg: params.cfg, accountId: params.accountId ?? null })
  if (!account.configured || !account.baseUrl) {
    throw new Error(`Inline not configured for account "${account.accountId}" (missing token or baseUrl)`)
  }
  const token = await resolveInlineToken(account)

  const target = parseInlineOutboundTarget({
    raw: params.to,
    context: "sendText",
  })

  const client = new InlineSdkClient({
    baseUrl: account.baseUrl,
    token,
  })

  await client.connect()
  try {
    // Inline "threads" are modeled as chats (chatId). OpenClaw's threadId is not a message id.
    // Only map OpenClaw replyToId -> Inline replyToMsgId.
    const replyToMsgId = parseInlineId(params.replyToId)

    const result = await client.sendMessage({
      ...(target.kind === "user" ? { userId: target.targetId } : { chatId: target.targetId }),
      text: params.text,
      ...(replyToMsgId != null ? { replyToMsgId } : {}),
      parseMarkdown: account.config.parseMarkdown ?? true,
    })
    const bestEffort =
      result.messageId != null ? String(result.messageId) : BigInt(Date.now()).toString()
    return {
      messageId: bestEffort,
      chatId: target.normalizedNumeric,
    }
  } finally {
    await client.close().catch(() => {})
  }
}

async function sendMediaInline(params: {
  cfg: OpenClawConfig
  to: string
  text: string
  mediaUrl: string
  accountId?: string | null
  replyToId?: string | null
}): Promise<{ messageId: string; chatId: string }> {
  const account = resolveInlineAccount({ cfg: params.cfg, accountId: params.accountId ?? null })
  if (!account.configured || !account.baseUrl) {
    throw new Error(`Inline not configured for account "${account.accountId}" (missing token or baseUrl)`)
  }
  const token = await resolveInlineToken(account)

  const target = parseInlineOutboundTarget({
    raw: params.to,
    context: "sendMedia",
  })
  const replyToMsgId = parseInlineId(params.replyToId)
  const caption = params.text.trim()

  const client = new InlineSdkClient({
    baseUrl: account.baseUrl,
    token,
  })

  await client.connect()
  try {
    const media = await uploadInlineMediaFromUrl({
      client,
      cfg: params.cfg,
      accountId: account.accountId,
      mediaUrl: params.mediaUrl,
    })

    const result = await client.sendMessage({
      ...(target.kind === "user" ? { userId: target.targetId } : { chatId: target.targetId }),
      ...(caption ? { text: caption } : {}),
      media,
      ...(replyToMsgId != null ? { replyToMsgId } : {}),
      ...(caption ? { parseMarkdown: account.config.parseMarkdown ?? true } : {}),
    })
    const bestEffort =
      result.messageId != null ? String(result.messageId) : BigInt(Date.now()).toString()
    return {
      messageId: bestEffort,
      chatId: target.normalizedNumeric,
    }
  } finally {
    await client.close().catch(() => {})
  }
}

function resolveDirectoryLimit(limit: number | null | undefined): number {
  const parsed = typeof limit === "number" ? Math.trunc(limit) : undefined
  return Math.max(1, Math.min(200, parsed ?? 50))
}

async function fetchInlineChatsSnapshot(params: {
  cfg: OpenClawConfig
  accountId?: string | null
}): Promise<{ chats: Chat[]; users: User[]; dialogByChatId: Map<string, Dialog> }> {
  return await withInlineClient({
    cfg: params.cfg,
    accountId: params.accountId ?? null,
    fn: async (client) => {
      const result = await client.invokeRaw(Method.GET_CHATS, {
        oneofKind: "getChats",
        getChats: {},
      })
      if (result.oneofKind !== "getChats") {
        throw new Error(`inline directory: expected getChats result, got ${String(result.oneofKind)}`)
      }
      const chats = result.getChats.chats ?? []
      const users = result.getChats.users ?? []
      const dialogByChatId = buildDialogMap(result.getChats.dialogs ?? [])
      return { chats, users, dialogByChatId }
    },
  })
}

function normalizeResolverInput(input: string): string {
  return input.trim()
}

function resolveInlineGroupCandidates(params: {
  chats: ReturnType<typeof toInlineGroupDirectoryEntry>[]
  input: string
}): Array<{ id: string; name?: string }> {
  const raw = normalizeResolverInput(params.input)
  if (!raw) return []

  const normalized = normalizeInlineTarget(raw) ?? raw
  const lowered = normalized.toLowerCase()
  if (/^[0-9]+$/.test(normalized)) {
    const exact = params.chats.find((chat) => chat.id === normalized)
    return exact ? [{ id: exact.id, name: exact.name }] : []
  }

  const byExactName = params.chats.filter((chat) => (chat.name ?? "").trim().toLowerCase() === lowered)
  if (byExactName.length > 0) {
    return byExactName.map((chat) => ({ id: chat.id, name: chat.name }))
  }

  return params.chats
    .filter((chat) => (chat.name ?? "").trim().toLowerCase().includes(lowered))
    .map((chat) => ({ id: chat.id, name: chat.name }))
}

function resolveInlineUserCandidates(params: {
  users: ReturnType<typeof toInlineUserDirectoryEntry>[]
  input: string
}): Array<{ id: string; name?: string }> {
  const raw = normalizeResolverInput(params.input)
  if (!raw) return []

  const withoutPrefix = raw.replace(/^inline:/i, "").replace(/^user:/i, "").trim()
  const normalized = withoutPrefix.startsWith("@") ? withoutPrefix.slice(1) : withoutPrefix
  const lowered = normalized.toLowerCase()

  if (/^[0-9]+$/.test(normalized)) {
    const exact = params.users.find((user) => user.id === normalized)
    return exact ? [{ id: exact.id, name: exact.name }] : []
  }

  const byHandle = params.users.filter((user) => (user.handle ?? "").replace(/^@/, "").toLowerCase() === lowered)
  if (byHandle.length > 0) {
    return byHandle.map((user) => ({ id: user.id, name: user.name }))
  }

  const byName = params.users.filter((user) => (user.name ?? "").trim().toLowerCase() === lowered)
  if (byName.length > 0) {
    return byName.map((user) => ({ id: user.id, name: user.name }))
  }

  return params.users
    .filter((user) => {
      const haystack = [user.name ?? "", user.handle ?? "", user.id].join("\n").toLowerCase()
      return haystack.includes(lowered)
    })
    .map((user) => ({ id: user.id, name: user.name }))
}

export const inlineChannelPlugin: ChannelPlugin<ResolvedInlineAccount> = {
  id: "inline",
  meta,
  capabilities: {
    chatTypes: ["direct", "group"],
    media: true,
    reactions: true,
    edit: true,
    reply: true,
    groupManagement: true,
    threads: false,
    nativeCommands: false,
    blockStreaming: true,
  },
  streaming: {
    blockStreamingCoalesceDefaults: { minChars: 1500, idleMs: 1000 },
  },
  reload: { configPrefixes: ["channels.inline"] },
  configSchema: buildChannelConfigSchema(InlineConfigSchema),

  config: {
    listAccountIds: (cfg) => listInlineAccountIds(cfg),
    resolveAccount: (cfg, accountId) => resolveInlineAccount({ cfg, accountId: accountId ?? null }),
    defaultAccountId: (cfg) => resolveDefaultInlineAccountId(cfg),
    isConfigured: (account) => account.configured,
    describeAccount: (account) => ({
      accountId: account.accountId,
      name: account.name,
      enabled: account.enabled,
      configured: account.configured,
      baseUrl: account.baseUrl ? "[set]" : "[missing]",
      tokenSource: account.token ? "config" : account.tokenFile ? "file" : "missing",
    }),
    resolveAllowFrom: ({ cfg, accountId }) =>
      (resolveInlineAccount({ cfg, accountId: accountId ?? null }).config.allowFrom ?? []).map(
        (entry) =>
        normalizeInlineAllowEntry(String(entry)),
      ),
    formatAllowFrom: ({ allowFrom }) =>
      allowFrom
        .map((entry) => String(entry).trim())
        .filter(Boolean)
        .map((entry) => normalizeInlineAllowEntry(entry)),
  },

  pairing: {
    idLabel: "inlineUserId",
    normalizeAllowEntry: (entry) => normalizeInlineAllowEntry(entry),
    notifyApproval: async ({ cfg, id }) => {
      await notifyPairingApprovedInline({ cfg, id })
    },
  },

  security: {
    resolveDmPolicy: ({ cfg, accountId, account }) => {
      const resolvedAccountId = accountId ?? account.accountId ?? DEFAULT_ACCOUNT_ID
      const useAccountPath = Boolean(cfg.channels?.inline?.accounts?.[resolvedAccountId])
      const basePath = useAccountPath
        ? `channels.inline.accounts.${resolvedAccountId}.`
        : "channels.inline."
      return {
        policy: account.config.dmPolicy ?? "pairing",
        allowFrom: account.config.allowFrom ?? [],
        policyPath: `${basePath}dmPolicy`,
        allowFromPath: `${basePath}allowFrom`,
        approveHint: formatPairingApproveHint("inline"),
        normalizeEntry: (raw) => normalizeInlineAllowEntry(raw),
      }
    },
    collectWarnings: ({ account, cfg }) => {
      const defaultGroupPolicy = cfg.channels?.defaults?.groupPolicy
      const groupPolicy = account.config.groupPolicy ?? defaultGroupPolicy ?? "allowlist"
      if (groupPolicy !== "open") {
        return []
      }
      const groupRulesConfigured =
        Boolean(account.config.groups) && Object.keys(account.config.groups ?? {}).length > 0
      if (groupRulesConfigured) {
        return [
          "- Inline groups: groupPolicy=\"open\" allows any group message to reach the agent (subject to mention policy). Set channels.inline.groupPolicy=\"allowlist\" for stricter routing.",
        ]
      }
      return [
        "- Inline groups: groupPolicy=\"open\" with no group rules means every group can trigger replies. Consider channels.inline.groupPolicy=\"allowlist\".",
      ]
    },
  },

  groups: {
    resolveRequireMention: ({ cfg, accountId, groupId }) => {
      const resolved = resolveInlineAccount({ cfg, accountId: accountId ?? null })
      return resolveInlineGroupRequireMention({
        cfg,
        groupId,
        accountId,
        requireMentionDefault: resolved.config.requireMention ?? false,
      })
    },
    resolveToolPolicy: ({ cfg, accountId, groupId, senderId, senderName, senderUsername, senderE164 }) =>
      resolveInlineGroupToolPolicy({
        cfg,
        groupId,
        accountId,
        senderId,
        senderName,
        senderUsername,
        senderE164,
      }),
  },

  messaging: {
    normalizeTarget: normalizeInlineTarget,
    targetResolver: {
      looksLikeId: looksLikeInlineTargetId,
      hint: "<chatId>",
    },
  },

  directory: {
    self: async ({ cfg, accountId }) =>
      await withInlineClient({
        cfg,
        accountId: accountId ?? null,
        fn: async (client) => {
          const result = await client.invokeRaw(Method.GET_ME, {
            oneofKind: "getMe",
            getMe: {},
          })
          if (result.oneofKind !== "getMe") {
            throw new Error(`inline directory: expected getMe result, got ${String(result.oneofKind)}`)
          }
          if (!result.getMe.user) {
            throw new Error("inline directory: missing current user from getMe")
          }
          return toInlineUserDirectoryEntry(result.getMe.user)
        },
      }),
    listPeers: async ({ cfg, accountId, query, limit }) => {
      const snapshot = await fetchInlineChatsSnapshot({
        cfg,
        accountId: accountId ?? null,
      })
      const normalizedQuery = normalizeSearchQuery(query)
      const maxItems = resolveDirectoryLimit(limit)
      return snapshot.users
        .map((user) => toInlineUserDirectoryEntry(user))
        .filter((user) => {
          if (!normalizedQuery) return true
          const haystack = [user.id, user.name ?? "", user.handle ?? ""].join("\n").toLowerCase()
          return matchesInlineQuery(haystack, normalizedQuery)
        })
        .slice(0, maxItems)
    },
    listGroups: async ({ cfg, accountId, query, limit }) => {
      const snapshot = await fetchInlineChatsSnapshot({
        cfg,
        accountId: accountId ?? null,
      })
      const normalizedQuery = normalizeSearchQuery(query)
      const maxItems = resolveDirectoryLimit(limit)
      return snapshot.chats
        .map((chat) => toInlineGroupDirectoryEntry(chat, snapshot.dialogByChatId))
        .filter((chat) => {
          if (!normalizedQuery) return true
          const haystack = [chat.id, chat.name ?? ""].join("\n").toLowerCase()
          return matchesInlineQuery(haystack, normalizedQuery)
        })
        .slice(0, maxItems)
    },
    listGroupMembers: async ({ cfg, accountId, groupId, limit }) =>
      await withInlineClient({
        cfg,
        accountId: accountId ?? null,
        fn: async (client) => {
          const normalizedGroupId = normalizeInlineTarget(groupId) ?? groupId.trim()
          if (!/^[0-9]+$/.test(normalizedGroupId)) {
            throw new Error(`inline directory: invalid groupId "${groupId}"`)
          }
          const chatId = BigInt(normalizedGroupId)
          const result = await client.invokeRaw(Method.GET_CHAT_PARTICIPANTS, {
            oneofKind: "getChatParticipants",
            getChatParticipants: { chatId },
          })
          if (result.oneofKind !== "getChatParticipants") {
            throw new Error(
              `inline directory: expected getChatParticipants result, got ${String(result.oneofKind)}`,
            )
          }
          const usersById = new Map(
            (result.getChatParticipants.users ?? []).map((user) => [String(user.id), user] as const),
          )
          const maxItems = resolveDirectoryLimit(limit)
          return (result.getChatParticipants.participants ?? [])
            .map((participant) => usersById.get(String(participant.userId)))
            .filter((user): user is User => Boolean(user))
            .map((user) => toInlineUserDirectoryEntry(user))
            .slice(0, maxItems)
        },
      }),
  },

  resolver: {
    resolveTargets: async ({ cfg, accountId, inputs, kind }) => {
      const snapshot = await fetchInlineChatsSnapshot({
        cfg,
        accountId: accountId ?? null,
      })
      if (kind === "group") {
        const groups = snapshot.chats.map((chat) => toInlineGroupDirectoryEntry(chat, snapshot.dialogByChatId))
        return inputs.map((input) => {
          const candidates = resolveInlineGroupCandidates({ chats: groups, input })
          if (candidates.length === 1) {
            const candidate = candidates[0]
            if (!candidate) {
              return { input, resolved: false, note: "group not found" }
            }
            return {
              input,
              resolved: true,
              id: candidate.id,
              ...(candidate.name ? { name: candidate.name } : {}),
            }
          }
          if (candidates.length > 1) {
            return { input, resolved: false, note: "multiple matching groups" }
          }
          return { input, resolved: false, note: "group not found" }
        })
      }

      const users = snapshot.users.map((user) => toInlineUserDirectoryEntry(user))
      return inputs.map((input) => {
        const candidates = resolveInlineUserCandidates({ users, input })
        if (candidates.length === 1) {
          const candidate = candidates[0]
          if (!candidate) {
            return { input, resolved: false, note: "user not found" }
          }
          return {
            input,
            resolved: true,
            id: candidate.id,
            ...(candidate.name ? { name: candidate.name } : {}),
          }
        }
        if (candidates.length > 1) {
          return { input, resolved: false, note: "multiple matching users" }
        }
        return { input, resolved: false, note: "user not found" }
      })
    },
  },

  actions: inlineMessageActions,

  outbound: {
    deliveryMode: "direct",
    chunker: (text, limit) => getInlineRuntime().channel.text.chunkMarkdownText(text, limit),
    chunkerMode: "markdown",
    textChunkLimit: 4000,
    sendPayload: async ({ cfg, to, payload, accountId, replyToId }) => {
      const text = payload.text ?? ""
      const payloadReplyToId = typeof payload.replyToId === "string" ? payload.replyToId.trim() : null
      const effectiveReplyToId = payloadReplyToId || replyToId || null
      const mediaUrls = payload.mediaUrls?.length
        ? payload.mediaUrls
        : payload.mediaUrl
          ? [payload.mediaUrl]
          : []

      if (mediaUrls.length === 0) {
        const result = await sendMessageInline({
          cfg,
          to,
          text,
          accountId: accountId ?? null,
          replyToId: effectiveReplyToId,
        })
        return { channel: "inline", to, messageId: result.messageId, chatId: result.chatId }
      }

      let finalResult: { messageId: string; chatId: string } | null = null
      for (let index = 0; index < mediaUrls.length; index += 1) {
        const mediaUrl = mediaUrls[index]
        if (!mediaUrl?.trim()) continue
        const isFirst = index === 0
        finalResult = await sendMediaInline({
          cfg,
          to,
          text: isFirst ? text : "",
          mediaUrl,
          accountId: accountId ?? null,
          replyToId: isFirst ? effectiveReplyToId : null,
        })
      }

      if (!finalResult) {
        const result = await sendMessageInline({
          cfg,
          to,
          text,
          accountId: accountId ?? null,
          replyToId: effectiveReplyToId,
        })
        return { channel: "inline", to, messageId: result.messageId, chatId: result.chatId }
      }
      return { channel: "inline", to, messageId: finalResult.messageId, chatId: finalResult.chatId }
    },
    sendText: async ({ cfg, to, text, accountId, replyToId, threadId }) => {
      // Inline threads are modeled as chats. OpenClaw threadId isn't a message id for Inline.
      const result = await sendMessageInline({
        cfg,
        to,
        text,
        accountId: accountId ?? null,
        replyToId: replyToId ?? null,
      })
      return { channel: "inline", to, messageId: result.messageId, chatId: result.chatId }
    },
    sendMedia: async ({ cfg, to, text, mediaUrl, accountId, replyToId, threadId }) => {
      if (!mediaUrl) {
        const result = await sendMessageInline({
          cfg,
          to,
          text,
          accountId: accountId ?? null,
          replyToId: replyToId ?? null,
        })
        return { channel: "inline", to, messageId: result.messageId, chatId: result.chatId }
      }

      // Inline threads are modeled as chats. OpenClaw threadId isn't a message id for Inline.
      const result = await sendMediaInline({
        cfg,
        to,
        text,
        mediaUrl,
        accountId: accountId ?? null,
        replyToId: replyToId ?? null,
      })
      return { channel: "inline", to, messageId: result.messageId, chatId: result.chatId }
    },
  },

  status: {
    defaultRuntime: {
      accountId: DEFAULT_ACCOUNT_ID,
      running: false,
      lastStartAt: null,
      lastStopAt: null,
      lastError: null,
    },
    buildChannelSummary: ({ snapshot }) => ({
      configured: snapshot.configured ?? false,
      running: snapshot.running ?? false,
      lastStartAt: snapshot.lastStartAt ?? null,
      lastStopAt: snapshot.lastStopAt ?? null,
      lastError: snapshot.lastError ?? null,
      lastInboundAt: snapshot.lastInboundAt ?? null,
      lastOutboundAt: snapshot.lastOutboundAt ?? null,
    }),
    buildAccountSnapshot: ({ account, runtime }) => ({
      accountId: account.accountId,
      name: account.name,
      enabled: account.enabled,
      configured: account.configured,
      baseUrl: account.baseUrl ? "[set]" : "[missing]",
      tokenSource: account.token ? "config" : account.tokenFile ? "file" : "missing",
      running: runtime?.running ?? false,
      lastStartAt: runtime?.lastStartAt ?? null,
      lastStopAt: runtime?.lastStopAt ?? null,
      lastError: runtime?.lastError ?? null,
      lastInboundAt: runtime?.lastInboundAt ?? null,
      lastOutboundAt: runtime?.lastOutboundAt ?? null,
    }),
  },

  gateway: {
    startAccount: async (ctx) => {
      const account = ctx.account
      if (!account.configured || !account.baseUrl) {
        throw new Error(
          `Inline not configured for account "${account.accountId}" (missing baseUrl or token)`,
        )
      }

      ctx.log?.info(`[${account.accountId}] starting Inline realtime monitor`)

      // Best-effort stop if already running for this account.
      const existing = activeMonitors.get(account.accountId)
      if (existing) {
        await existing.stop().catch(() => {})
        activeMonitors.delete(account.accountId)
      }

      const now = Date.now()
      ctx.setStatus({
        ...ctx.getStatus(),
        accountId: account.accountId,
        configured: true,
        running: true,
        lastStartAt: now,
        lastError: null,
      })

      const handle = await monitorInlineProvider({
        cfg: ctx.cfg as OpenClawConfig,
        account,
        runtime: ctx.runtime,
        abortSignal: ctx.abortSignal,
        ...(ctx.log ? { log: ctx.log } : {}),
        statusSink: (patch) => {
          ctx.setStatus({ ...ctx.getStatus(), ...patch })
        },
      })

      activeMonitors.set(account.accountId, handle)
      return handle
    },

    stopAccount: async (ctx) => {
      const existing = activeMonitors.get(ctx.account.accountId)
      if (existing) {
        await existing.stop().catch(() => {})
        activeMonitors.delete(ctx.account.accountId)
      }
      ctx.setStatus({
        ...ctx.getStatus(),
        running: false,
        lastStopAt: Date.now(),
      })
    },
  },
}
