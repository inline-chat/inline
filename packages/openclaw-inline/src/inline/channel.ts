import {
  buildChannelConfigSchema,
  DEFAULT_ACCOUNT_ID,
  formatPairingApproveHint,
  PAIRING_APPROVED_MESSAGE,
  type ChannelPlugin,
  type OpenClawConfig,
} from "openclaw/plugin-sdk"
import { InlineSdkClient } from "@inline-chat/realtime-sdk"
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
import { getInlineRuntime } from "../runtime.js"

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

  const normalizedTarget = normalizeInlineTarget(params.to) ?? params.to.trim()
  if (!normalizedTarget) {
    throw new Error("inline sendText: missing target")
  }
  if (!/^[0-9]+$/.test(normalizedTarget)) {
    throw new Error(`inline sendText: invalid target "${params.to}" (expected chat id)`)
  }

  const chatId = BigInt(normalizedTarget)

  const client = new InlineSdkClient({
    baseUrl: account.baseUrl,
    token,
  })

  await client.connect()
  try {
    const parseInlineId = (raw: unknown): bigint | undefined => {
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

    // Inline "threads" are modeled as chats (chatId). OpenClaw's threadId is not a message id.
    // Only map OpenClaw replyToId -> Inline replyToMsgId.
    const replyToMsgId = parseInlineId(params.replyToId)

    const result = await client.sendMessage({
      chatId,
      text: params.text,
      ...(replyToMsgId != null ? { replyToMsgId } : {}),
      parseMarkdown: account.config.parseMarkdown ?? true,
    })
    const bestEffort =
      result.messageId != null ? String(result.messageId) : BigInt(Date.now()).toString()
    return { messageId: bestEffort, chatId: normalizedTarget }
  } finally {
    await client.close().catch(() => {})
  }
}

export const inlineChannelPlugin: ChannelPlugin<ResolvedInlineAccount> = {
  id: "inline",
  meta,
  capabilities: {
    chatTypes: ["direct", "group"],
    media: false,
    reactions: false,
    threads: false,
    nativeCommands: false,
    blockStreaming: true,
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
  },

  messaging: {
    normalizeTarget: normalizeInlineTarget,
    targetResolver: {
      looksLikeId: looksLikeInlineTargetId,
      hint: "<chatId>",
    },
  },

  outbound: {
    deliveryMode: "direct",
    chunker: (text, limit) => getInlineRuntime().channel.text.chunkMarkdownText(text, limit),
    chunkerMode: "markdown",
    textChunkLimit: 4000,
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
      // Inline threads are modeled as chats. OpenClaw threadId isn't a message id for Inline.
      const combined = mediaUrl ? `${text}\n\nAttachment: ${mediaUrl}` : text
      const result = await sendMessageInline({
        cfg,
        to,
        text: combined,
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
