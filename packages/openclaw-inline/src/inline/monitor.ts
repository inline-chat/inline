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
import { InlineSdkClient, JsonFileStateStore, type Message } from "@inline-chat/realtime-sdk"
import { resolveInlineToken, type ResolvedInlineAccount } from "./accounts.js"
import { getInlineRuntime } from "../runtime.js"

const CHANNEL_ID = "inline" as const

type InlineMonitorHandle = {
  stop: () => Promise<void>
}

type StatusSink = (patch: { lastInboundAt?: number; lastOutboundAt?: number; lastError?: string }) => void

type CachedChatInfo = {
  kind: "direct" | "group"
  title: string | null
}

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

  const loop = (async () => {
    try {
      for await (const event of client.events()) {
        if (abortSignal.aborted) break
        if (event.kind !== "message.new") continue

        const msg = event.message
        const rawBody = messageText(msg)
        if (!rawBody) continue

        // Ignore echoes / our own outbound messages.
        if (msg.out || msg.fromId === me.userId) continue

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

        const requireMention = isGroup ? (account.config.requireMention ?? true) : false
        const mentionGate = resolveMentionGatingWithBypass({
          isGroup,
          requireMention,
          canDetectMention: typeof msg.mentioned === "boolean" || mentionRegexes.length > 0,
          wasMentioned,
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
          body: rawBody,
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
          Provider: CHANNEL_ID,
          Surface: CHANNEL_ID,
          MessageSid: String(msg.id),
          ...(msg.replyToMsgId != null ? { ReplyToId: String(msg.replyToMsgId) } : {}),
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

        const { onModelSelected, ...prefixOptions } = createReplyPrefixOptions({
          cfg,
          agentId: route.agentId,
          channel: CHANNEL_ID,
          accountId: account.accountId,
        })

        const typingCallbacks = createTypingCallbacks({
          start: () => client.sendTyping({ chatId, typing: true }),
          stop: () => client.sendTyping({ chatId, typing: false }),
          onStartError: (err) => runtime.error?.(`inline typing start failed: ${String(err)}`),
          onStopError: (err) => runtime.error?.(`inline typing stop failed: ${String(err)}`),
        })

        const parseMarkdown = account.config.parseMarkdown ?? true

        await core.channel.reply.dispatchReplyWithBufferedBlockDispatcher({
          ctx: ctxPayload,
          cfg,
          dispatcherOptions: {
            ...prefixOptions,
            ...typingCallbacks,
            deliver: async (payload) => {
              const text = (payload.text ?? "").trim()
              const mediaList = payload.mediaUrls?.length
                ? payload.mediaUrls
                : payload.mediaUrl
                  ? [payload.mediaUrl]
                  : []
              const mediaBlock = mediaList.length ? mediaList.map((url) => `Attachment: ${url}`).join("\n") : ""
              const combined = text
                ? mediaBlock
                  ? `${text}\n\n${mediaBlock}`
                  : text
                : mediaBlock

              if (!combined.trim()) return

              let replyToMsgId: bigint | undefined
              if (payload.replyToId != null) {
                try {
                  replyToMsgId = BigInt(payload.replyToId)
                } catch {
                  // ignore
                }
              }
              await client.sendMessage({
                chatId,
                text: combined,
                ...(replyToMsgId != null ? { replyToMsgId } : {}),
                parseMarkdown,
              })
              statusSink?.({ lastOutboundAt: Date.now() })
            },
            onError: (err, info) => runtime.error?.(`inline ${info.kind} reply failed: ${String(err)}`),
          },
          replyOptions: {
            onModelSelected,
            blockReplyTimeoutMs: 25_000,
          },
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
