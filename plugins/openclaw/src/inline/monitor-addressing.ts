import {
  findCommandByNativeName,
  listNativeCommandSpecsForConfig,
} from "openclaw/plugin-sdk/native-command-registry"
import { isAbortRequestText } from "openclaw/plugin-sdk/command-primitives-runtime"
import { prepareSkillCommandsForAgents } from "openclaw/plugin-sdk/skill-commands-runtime"
import { getPluginCommandSpecs } from "openclaw/plugin-sdk/plugin-runtime"
import type { OpenClawConfig } from "openclaw/plugin-sdk/core"
import { DialogFollowMode, type Message } from "@inline-chat/realtime-sdk"
import type { ResolvedInlineAccount } from "./accounts.js"
import { summarizeInlineMessageContent, type InlineMessageEntitySummary } from "./message-content.js"
import {
  shouldSyncInlineNativeCommandsForAccount,
  shouldSyncInlineNativeSkillsForAccount,
} from "./bot-commands-sync.js"
import { listInlineBuiltinCommandSpecs } from "./threadreply-command.js"
import { DIALOG_FOLLOW_MODE_UNFOLLOWED, listInlineFollowCommandSpecs } from "./follow-command.js"
import { listInlineMaintenanceCommandSpecs } from "./maintenance-command-specs.js"
import { CHANNEL_ID, isRecord } from "./monitor-shared.js"

const INLINE_NATIVE_COMMAND_PROVIDER = CHANNEL_ID
const INLINE_NATIVE_COMMAND_CALLBACK_PREFIX = "icmd:"

type InlineMentionSource =
  | "explicit_bot"
  | "subteam"
  | "implicit_thread"
  | "command_bypass"
  | "none"

export function normalizeInlineUsername(raw: string | undefined): string | undefined {
  const trimmed = raw?.trim()
  if (!trimmed) return undefined
  return trimmed.startsWith("@") ? trimmed.slice(1) : trimmed
}

export function resolveInlineCommandTarget(raw: string, botUsername: string | undefined): {
  body: string
  targeted: boolean
  addressedToMe: boolean
} {
  const normalized = raw.trim()
  const match = normalized.match(/^\/([^\s@]+)@([a-z0-9_]+)(?=\s|$)([\s\S]*)$/i)
  if (!match) return { body: normalized, targeted: false, addressedToMe: false }
  const [, command, targetUsername, suffix] = match
  const normalizedBotUsername = normalizeInlineUsername(botUsername)?.toLowerCase()
  const addressedToMe = Boolean(
    normalizedBotUsername && targetUsername?.toLowerCase() === normalizedBotUsername,
  )
  return {
    body: addressedToMe ? `/${command}${suffix ?? ""}` : normalized,
    targeted: true,
    addressedToMe,
  }
}

export function normalizeInlineCommandBody(raw: string, botUsername: string | undefined): string {
  return resolveInlineCommandTarget(raw, botUsername).body
}

// The app attaches the bot a command was picked for to a leading command
// entity. Returns that bot's user id, or null when the command names none.
export function leadingInlineBotCommandTargetUserId(msg: Message): string | null {
  const text = typeof msg.message === "string" ? msg.message : ""
  for (const entity of msg.entities?.entities ?? []) {
    if (entity.entity.oneofKind !== "botCommand") continue
    const offset = Number(entity.offset)
    if (!Number.isInteger(offset) || offset < 0) continue
    if (text.slice(0, offset).trim()) continue
    const botUserId = entity.entity.botCommand.botUserId
    return botUserId > 0n ? String(botUserId) : null
  }
  return null
}

// The server stamps the bot a bare command settles on; no stamp means no bot won.
export function startsWithUnclaimedInlineBotCommand(msg: Message): boolean {
  const text = typeof msg.message === "string" ? msg.message : ""
  for (const entity of msg.entities?.entities ?? []) {
    if (entity.entity.oneofKind !== "botCommand") continue
    const offset = Number(entity.offset)
    if (!Number.isInteger(offset) || offset < 0) continue
    if (text.slice(0, offset).trim()) continue
    return entity.entity.botCommand.botUserId <= 0n
  }
  return false
}

function isInlineBotCommandForOtherBot(msg: Message, meId: bigint): boolean {
  const target = leadingInlineBotCommandTargetUserId(msg)
  return target != null && target !== String(meId)
}

// Service notices (thread backlinks, member changes, ...) are system records, not
// requests. They never wake the agent; Hermes and the bridge skip them the same way.
export function isInlineServiceMessage(msg: Message): boolean {
  const record = msg as unknown as Record<string, unknown>
  const raw = isRecord(record.raw) ? record.raw : undefined
  return isRecord(record.serviceMessage) || isRecord(raw?.serviceMessage)
}

export function isInlineAbortRequestMessage(msg: Message, botUsername: string | undefined, meId: bigint): boolean {
  const text = typeof msg.message === "string" ? msg.message : ""
  if (isInlineBotCommandForOtherBot(msg, meId)) return false
  return isAbortRequestText(text, botUsername ? { botUsername } : undefined)
}

export function findInlineNativeCommandFromBody(commandBody: string): NonNullable<ReturnType<typeof findCommandByNativeName>> | null {
  const match = commandBody.trim().match(/^\/([^\s]+)(?:\s+[\s\S]*)?$/)
  if (!match?.[1]) return null
  return findCommandByNativeName(match[1], INLINE_NATIVE_COMMAND_PROVIDER) ?? null
}

export function resolveInlineCommandNameFromBody(commandBody: string): string | null {
  const match = commandBody.trim().match(/^\/([^\s]+)(?:\s+[\s\S]*)?$/)
  const raw = match?.[1]?.trim().toLowerCase()
  return raw || null
}

export function buildInlineNativeCommandCallbackData(commandText: string): string {
  return `${INLINE_NATIVE_COMMAND_CALLBACK_PREFIX}${commandText}`
}

export function parseInlineNativeCommandCallbackData(raw: string | undefined): string | null {
  if (!raw) return null
  const trimmed = raw.trim()
  if (!trimmed.startsWith(INLINE_NATIVE_COMMAND_CALLBACK_PREFIX)) return null
  const commandText = trimmed.slice(INLINE_NATIVE_COMMAND_CALLBACK_PREFIX.length).trim()
  return commandText.startsWith("/") ? commandText : null
}

export function listHostInlinePluginCommandSpecs(cfg: OpenClawConfig): Array<{ name: string; description: string }> {
  return getPluginCommandSpecs("inline", { config: cfg })
}

function listInlinePluginCommandSpecs(cfg: OpenClawConfig): Array<{ name: string; description: string }> {
  return [
    ...listHostInlinePluginCommandSpecs(cfg),
    ...listInlineFollowCommandSpecs(),
    ...listInlineBuiltinCommandSpecs(),
    ...listInlineMaintenanceCommandSpecs(),
  ]
}

export function hasInlineCommandSpec(
  specs: Array<{ name: string }>,
  commandName: string,
): boolean {
  const normalized = commandName.trim().toLowerCase()
  if (!normalized) return false
  return specs.some((spec) => spec.name.trim().toLowerCase() === normalized)
}

export function isInlineThreadReplyCommandBody(commandBody: string): boolean {
  return resolveInlineCommandNameFromBody(commandBody) === "threads"
}

export function parseInlineCommandArgs(commandBody: string): string {
  const match = commandBody.trim().match(/^\/[^\s]+(?:\s+([\s\S]*))?$/)
  return match?.[1]?.trim() ?? ""
}

export async function isInlineNativeCommandBody(params: {
  cfg: OpenClawConfig
  account: ResolvedInlineAccount
  commandBody: string
  agentId: string
}): Promise<boolean> {
  if (!shouldSyncInlineNativeCommandsForAccount({ cfg: params.cfg, account: params.account })) {
    return false
  }
  const commandName = resolveInlineCommandNameFromBody(params.commandBody)
  if (!commandName) return false

  const skillCommands = shouldSyncInlineNativeSkillsForAccount({
    cfg: params.cfg,
    account: params.account,
  })
    ? await prepareSkillCommandsForAgents({
        cfg: params.cfg,
        agentIds: [params.agentId],
      })
    : []
  const commandSpecs = listNativeCommandSpecsForConfig(params.cfg, {
    skillCommands,
    provider: INLINE_NATIVE_COMMAND_PROVIDER,
  })
  for (const spec of commandSpecs) {
    if (spec.name.trim().toLowerCase() === commandName) return true
  }
  for (const spec of listInlinePluginCommandSpecs(params.cfg)) {
    if (spec.name.trim().toLowerCase() === commandName) return true
  }
  return false
}

function escapeInlineRegExp(raw: string): string {
  return raw.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
}

export function stripInlineBotMention(raw: string, botUsername: string | undefined): string {
  const username = normalizeInlineUsername(botUsername)
  if (!username) return raw
  const mention = new RegExp(`(^|\\s)@${escapeInlineRegExp(username)}(?=$|[\\s,.:;!?])(?:[\\s,.:;!?]+)?`, "gi")
  return raw.replace(mention, "$1").replace(/[ \t]{2,}/g, " ").trim()
}

export function stripInlineBotMentionEntityText(text: string | null, botUsername: string | undefined): string | null {
  const username = normalizeInlineUsername(botUsername)?.toLowerCase()
  if (!text || !username) return text
  const token = `@${username}`
  const parts = text
    .split(" | ")
    .filter((part) => {
      const normalized = part.trim().toLowerCase()
      return normalized !== `username mention "${token}"` && !normalized.startsWith(`mention "${token}"`)
    })
  const next = parts.join(" | ").trim()
  return next || null
}

export function collectInlineMentionedUserIds(
  content: ReturnType<typeof summarizeInlineMessageContent> | null,
): string[] {
  const ids = new Set<string>()
  for (const entity of content?.entities ?? []) {
    if (entity.type !== "mention" || !entity.userId) continue
    ids.add(entity.userId)
  }
  return [...ids]
}

// User ids in the run of mentions a message starts with, in order. That run
// names who the message is for ("@alice @bot compare").
export function leadingInlineMentionUserIds(params: {
  content: ReturnType<typeof summarizeInlineMessageContent> | null
  messageText: string | undefined
}): string[] {
  const mentions = (params.content?.entities ?? [])
    .filter((entity): entity is InlineMessageEntitySummary & { userId: string } =>
      entity.type === "mention" &&
      Boolean(entity.userId) &&
      Number.isInteger(entity.offset) &&
      entity.offset >= 0 &&
      Number.isInteger(entity.length) &&
      entity.length > 0)
    .sort((a, b) => a.offset - b.offset)
  // Inline entity offsets use UTF-16 code units, which matches JavaScript slice.
  const text = params.messageText ?? ""
  const leading: string[] = []
  let cursor = 0
  for (const mention of mentions) {
    if (mention.offset < cursor) break
    if (text.slice(cursor, mention.offset).replace(/,/g, "").trim()) break
    leading.push(mention.userId)
    cursor = mention.offset + mention.length
  }
  return leading
}

export function isInlineDialogFollowing(followMode: unknown): boolean {
  if (followMode == null || typeof followMode === "boolean") return false
  if (typeof followMode === "number") return followMode === DialogFollowMode.FOLLOWING
  if (typeof followMode === "bigint") return followMode === BigInt(DialogFollowMode.FOLLOWING)
  const text = String(followMode).trim().toLowerCase()
  return (
    text === String(DialogFollowMode.FOLLOWING) ||
    text === "following" ||
    text === "follow_mode_following" ||
    text === "dialog_following"
  )
}

export function isInlineDialogExplicitlyUnfollowed(followMode: unknown): boolean {
  if (followMode == null || typeof followMode === "boolean") return false
  if (typeof followMode === "number") return followMode === DIALOG_FOLLOW_MODE_UNFOLLOWED
  if (typeof followMode === "bigint") {
    return followMode === BigInt(DIALOG_FOLLOW_MODE_UNFOLLOWED)
  }
  const text = String(followMode).trim().toLowerCase()
  return (
    text === String(DIALOG_FOLLOW_MODE_UNFOLLOWED) ||
    text === "unfollowed" ||
    text === "follow_mode_unfollowed" ||
    text === "dialog_unfollowed"
  )
}

// Only structured Inline addressing wakes the agent; words such as its name never do.
export function resolveInlineMentionSource(params: {
  nativeMentioned: boolean
  implicitMention: boolean
  shouldBypassMention: boolean
}): InlineMentionSource {
  if (params.nativeMentioned) return "explicit_bot"
  if (params.shouldBypassMention) return "command_bypass"
  if (params.implicitMention) return "implicit_thread"
  return "none"
}
