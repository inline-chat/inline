import type {
  OpenClawPluginApi,
  OpenClawPluginCommandDefinition,
  PluginCommandContext,
} from "openclaw/plugin-sdk/channel-entry-contract"
import type { OpenClawConfig } from "openclaw/plugin-sdk/core"
import {
  DialogFollowMode,
  InlineSdkClient,
  Method,
  type InputPeer,
} from "@inline-chat/realtime-sdk"
import { resolveInlineAccount, resolveInlineToken } from "./accounts.js"
import { normalizeInlineTarget } from "./normalize.js"

export type InlineFollowCommand = "follow" | "unfollow"
export type InlineFollowMode = "following" | "unfollowed"
export type InlineFollowTarget =
  | { chatId: bigint }
  | { userId: bigint }

type InlineFollowClient = Pick<InlineSdkClient, "invokeUncheckedRaw">

type InlineFollowCommandSpec = {
  name: InlineFollowCommand
  description: string
  acceptsArgs: boolean
}

const INLINE_FOLLOW_COMMAND_DESCRIPTIONS: Record<InlineFollowCommand, string> = {
  follow: "Explicitly follow this Inline chat or thread",
  unfollow: "Explicitly unfollow this Inline chat or thread",
}

// The server contract defines UNFOLLOWED = 2, but the currently published
// public protocol enum only names UNSPECIFIED and FOLLOWING.
export const DIALOG_FOLLOW_MODE_UNFOLLOWED = 2 as DialogFollowMode

export function listInlineFollowCommandSpecs(): InlineFollowCommandSpec[] {
  return (["follow", "unfollow"] as const).map((name) => ({
    name,
    description: INLINE_FOLLOW_COMMAND_DESCRIPTIONS[name],
    acceptsArgs: false,
  }))
}

export function parseInlineFollowCommandBody(
  commandBody: string,
): { command: InlineFollowCommand; args: string } | null {
  const match = commandBody.trim().match(/^\/(follow|unfollow)(?:\s+([\s\S]*))?$/i)
  if (!match?.[1]) return null
  return {
    command: match[1].toLowerCase() as InlineFollowCommand,
    args: match[2]?.trim() ?? "",
  }
}

function parsePositiveId(raw: unknown): bigint | null {
  const value = typeof raw === "string" || typeof raw === "number"
    ? String(raw).trim()
    : ""
  if (!/^[0-9]+$/.test(value)) return null
  const parsed = BigInt(value)
  return parsed > 0n ? parsed : null
}

export function resolveInlineFollowCommandTarget(
  ctx: Pick<PluginCommandContext, "from" | "messageThreadId" | "senderId">,
): InlineFollowTarget | null {
  const threadId = parsePositiveId(ctx.messageThreadId)
  if (threadId != null) return { chatId: threadId }

  const from = ctx.from?.trim() ?? ""
  if (/(^|:)chat:/i.test(from)) {
    const chatId = parsePositiveId(normalizeInlineTarget(from))
    return chatId != null ? { chatId } : null
  }

  const userId = parsePositiveId(ctx.senderId)
  return userId != null ? { userId } : null
}

function inputPeerFromTarget(target: InlineFollowTarget): InputPeer {
  return "chatId" in target
    ? {
        type: {
          oneofKind: "chat",
          chat: { chatId: target.chatId },
        },
      }
    : {
        type: {
          oneofKind: "user",
          user: { userId: target.userId },
        },
      }
}

export function inlineFollowModeForCommand(command: InlineFollowCommand): {
  mode: InlineFollowMode
  protocolMode: DialogFollowMode
} {
  return command === "follow"
    ? { mode: "following", protocolMode: DialogFollowMode.FOLLOWING }
    : { mode: "unfollowed", protocolMode: DIALOG_FOLLOW_MODE_UNFOLLOWED }
}

export async function updateInlineFollowMode(params: {
  client: InlineFollowClient
  target: InlineFollowTarget
  command: InlineFollowCommand
}): Promise<InlineFollowMode> {
  const { mode, protocolMode } = inlineFollowModeForCommand(params.command)
  await params.client.invokeUncheckedRaw(Method.UPDATE_DIALOG_FOLLOW_MODE, {
    oneofKind: "updateDialogFollowMode",
    updateDialogFollowMode: {
      peerId: inputPeerFromTarget(params.target),
      followMode: protocolMode,
    },
  })
  return mode
}

export function inlineFollowCommandSuccessText(command: InlineFollowCommand): string {
  return command === "follow"
    ? "Following this chat—eligible messages can wake OpenClaw without an @mention."
    : "Unfollowed this chat—automatic follow and reply wakes are off."
}

export function inlineFollowCommandUsageText(command: InlineFollowCommand): string {
  return `Usage: /${command}`
}

export function inlineFollowCommandFailureText(command: InlineFollowCommand): string {
  return `Could not update Inline follow mode. Try /${command} again.`
}

export function summarizeInlineFollowCommandError(error: unknown): string {
  const detail = error instanceof Error
    ? `${error.name}: ${error.message}`
    : String(error)
  const redacted = detail
    .replace(/\bBearer\s+\S+/gi, "Bearer <redacted>")
    .replace(/https?:\/\/\S+/gi, (raw) => {
      try {
        const url = new URL(raw)
        return `${url.protocol}//${url.host}`
      } catch {
        return "<redacted-url>"
      }
    })
  return redacted.length > 500 ? `${redacted.slice(0, 499)}…` : redacted
}

async function withInlineFollowClient<T>(params: {
  cfg: OpenClawConfig
  accountId?: string | null
  fn: (client: InlineSdkClient) => Promise<T>
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
    return await params.fn(client)
  } finally {
    await client.close().catch(() => {})
  }
}

export async function handleInlineFollowCommand(
  api: OpenClawPluginApi,
  command: InlineFollowCommand,
  ctx: PluginCommandContext,
) {
  if (!ctx.isAuthorizedSender) {
    return { text: "This command requires authorization." }
  }
  if (ctx.args?.trim()) {
    return { text: inlineFollowCommandUsageText(command) }
  }
  const target = resolveInlineFollowCommandTarget(ctx)
  if (!target) {
    return { text: `/${command} is only available inside an Inline chat or reply thread.` }
  }

  try {
    const cfg = api.runtime.config.current() as OpenClawConfig
    await withInlineFollowClient({
      cfg,
      ...(ctx.accountId ? { accountId: ctx.accountId } : {}),
      fn: async (client) => {
        await updateInlineFollowMode({ client, target, command })
      },
    })
    return { text: inlineFollowCommandSuccessText(command) }
  } catch (error) {
    api.logger.warn?.(`[inline] /${command} failed: ${summarizeInlineFollowCommandError(error)}`)
    return { text: inlineFollowCommandFailureText(command) }
  }
}

export function createInlineFollowCommands(
  api: OpenClawPluginApi,
): OpenClawPluginCommandDefinition[] {
  return listInlineFollowCommandSpecs().map((spec) => ({
    ...spec,
    nativeNames: { inline: spec.name },
    channels: ["inline"],
    handler: async (ctx) => await handleInlineFollowCommand(api, spec.name, ctx),
  }))
}
