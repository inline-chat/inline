import type { AnyAgentTool, OpenClawConfig } from "openclaw/plugin-sdk/core"
import { DialogFollowMode, type InlineSdkClient } from "@inline-chat/realtime-sdk"
import {
  DIALOG_FOLLOW_MODE_UNFOLLOWED,
  markInlineFollowModeChanged,
  updateInlineFollowMode,
  withInlineFollowClient,
} from "./follow-command.js"
import { parseCurrentInlineTarget, parseInlineTarget, readStringCandidate } from "./tool-targets.js"
import { jsonResult } from "../openclaw-compat.js"

type InlineFollowToolContext = {
  config?: OpenClawConfig
  agentAccountId?: string
  sessionKey?: string
  messageChannel?: string
}

type InlineFollowToolArgs = {
  action?: string
  to?: string
  target?: string
  chatId?: string
  accountId?: string
}

type InlineFollowToolAction = "status" | "follow" | "unfollow"
type InlineFollowState = "following" | "unfollowed" | "default"

const InlineFollowToolParameters = {
  type: "object",
  additionalProperties: false,
  properties: {
    action: {
      type: "string",
      enum: ["status", "follow", "unfollow"],
      description:
        "`status` reads whether you follow the chat. `follow` lets its messages reach you without an @mention. `unfollow` limits you to messages addressed to you.",
    },
    to: {
      type: "string",
      description:
        "Optional Inline group chat or reply thread (`chat:<id>` or bare chat id). Defaults to the current Inline chat.",
    },
    target: {
      type: "string",
      description: "Alias for `to`.",
    },
    chatId: {
      type: "string",
      description: "Explicit chat id alias.",
    },
    accountId: {
      type: "string",
      description: "Optional Inline account id override.",
    },
  },
  required: ["action"],
} as const

function resolveInlineFollowToolAction(raw: unknown): InlineFollowToolAction {
  const action = typeof raw === "string" ? raw.trim().toLowerCase() : ""
  if (action === "status" || action === "follow" || action === "unfollow") return action
  throw new Error("inline_follow: action must be status, follow, or unfollow")
}

function inlineFollowStateFromMode(mode: unknown): InlineFollowState {
  if (mode === DialogFollowMode.FOLLOWING) return "following"
  if (mode === DIALOG_FOLLOW_MODE_UNFOLLOWED) return "unfollowed"
  return "default"
}

async function readInlineFollowState(
  client: Pick<InlineSdkClient, "getChat">,
  chatId: bigint,
): Promise<InlineFollowState> {
  const chat = await client.getChat({ chatId })
  return inlineFollowStateFromMode(chat.dialogFollowMode)
}

export function createInlineFollowTool(ctx: InlineFollowToolContext): AnyAgentTool {
  return {
    name: "inline_follow",
    label: "Inline Follow",
    description:
      "Read or change whether you follow an Inline group chat or reply thread. Applies to your own bot account only. Use it when someone asks you to follow or unfollow; the result reports the state Inline actually has.",
    parameters: InlineFollowToolParameters,
    execute: async (_toolCallId, rawArgs) => {
      if (!ctx.config) {
        throw new Error("inline_follow: missing OpenClaw config")
      }
      const args = rawArgs as InlineFollowToolArgs
      const action = resolveInlineFollowToolAction(args.action)
      const explicitTarget = readStringCandidate(args.to, args.target, args.chatId)
      const target = explicitTarget
        ? parseInlineTarget(explicitTarget, "target")
        : parseCurrentInlineTarget(ctx)
      if (!target) {
        throw new Error("inline_follow: pass `to` outside an Inline chat")
      }
      if (target.peerId.type.oneofKind !== "chat") {
        throw new Error("inline_follow: follow state applies to group chats and reply threads, not direct messages")
      }
      const chatId = target.peerId.type.chat.chatId

      return await withInlineFollowClient({
        cfg: ctx.config,
        accountId: args.accountId ?? ctx.agentAccountId ?? null,
        fn: async (client, accountId) => {
          if (action === "status") {
            return jsonResult({
              ok: true,
              accountId,
              chatId: String(chatId),
              followMode: await readInlineFollowState(client, chatId),
            })
          }

          let writeError: unknown = null
          try {
            await updateInlineFollowMode({ client, target: { chatId }, command: action })
          } catch (error) {
            writeError = error
          }
          markInlineFollowModeChanged({ accountId, chatId })

          // A lost response can hide a write that landed, so the readback decides.
          let followMode: InlineFollowState
          try {
            followMode = await readInlineFollowState(client, chatId)
          } catch (readError) {
            throw writeError ?? new Error(
              `inline_follow: ${action} was sent but the follow state could not be read back: ${String(readError)}`,
            )
          }
          const expected: InlineFollowState = action === "follow" ? "following" : "unfollowed"
          if (followMode !== expected) {
            throw writeError ?? new Error(`inline_follow: follow state is ${followMode} after ${action}`)
          }
          return jsonResult({
            ok: true,
            accountId,
            chatId: String(chatId),
            followMode,
          })
        },
      })
    },
  } as AnyAgentTool
}
