import type { AnyAgentTool, OpenClawConfig } from "openclaw/plugin-sdk/core"
import { Method, type InlineSdkClient } from "@inline-chat/realtime-sdk"
import { withInlineFollowClient } from "./follow-command.js"
import { parseCurrentInlineTarget, type InlinePeerTarget } from "./tool-targets.js"
import {
  INLINE_LIVE_CONFIG_WRITE_AFTER_WRITE,
  resolveCurrentMode,
  setGroupMode,
} from "./threadreply-command.js"
import { jsonResult } from "../openclaw-compat.js"

type InlineReplyThreadsConfigRuntime = {
  current: () => unknown
  mutateConfigFile: (params: {
    afterWrite: typeof INLINE_LIVE_CONFIG_WRITE_AFTER_WRITE
    mutate: (draft: OpenClawConfig) => void
  }) => Promise<{ nextConfig: unknown }>
}

type InlineReplyThreadsToolContext = {
  agentAccountId?: string
  sessionKey?: string
  messageChannel?: string
  senderIsOwner?: boolean
}

const InlineReplyThreadsToolParameters = {
  type: "object",
  additionalProperties: false,
  properties: {
    action: {
      type: "string",
      enum: ["status", "auto", "on", "reset"],
      description:
        "`status` reads this chat's setting. `auto` answers in the chat and starts a thread when someone asks. `on` answers each top-level message in a reply thread. `reset` removes this chat's setting.",
    },
  },
  required: ["action"],
} as const

// Asked from inside a reply thread, the setting belongs to the chat it hangs off.
async function resolveInlineSettingsChatId(
  client: Pick<InlineSdkClient, "invokeRaw">,
  target: InlinePeerTarget,
): Promise<string> {
  const result = await client.invokeRaw(Method.GET_CHAT, {
    oneofKind: "getChat",
    getChat: { peerId: target.peerId, includeRecentMessages: false },
  })
  const chat = result.oneofKind === "getChat" ? result.getChat.chat : undefined
  if (!chat?.id) throw new Error("inline_reply_threads: could not read the current chat")
  return String(chat.parentChatId ?? chat.id)
}

export function createInlineReplyThreadsTool(
  ctx: InlineReplyThreadsToolContext,
  configRuntime: InlineReplyThreadsConfigRuntime,
): AnyAgentTool {
  return {
    name: "inline_reply_threads",
    label: "Inline Reply Threads",
    description:
      "Read or change whether your answers in the current Inline chat go in reply threads, DMs included. Use it when someone asks you to always or never answer in threads here. Changing it is limited to the OpenClaw owner; anyone else authorized can use /threads.",
    parameters: InlineReplyThreadsToolParameters,
    execute: async (_toolCallId, rawArgs) => {
      const action = String((rawArgs as { action?: unknown }).action ?? "").trim().toLowerCase()
      if (action !== "status" && action !== "auto" && action !== "on" && action !== "reset") {
        throw new Error("inline_reply_threads: action must be status, auto, on, or reset")
      }
      if (action !== "status" && ctx.senderIsOwner !== true) {
        throw new Error("inline_reply_threads: changing reply threads needs the OpenClaw owner, or /threads")
      }
      const target = parseCurrentInlineTarget(ctx)
      if (!target) throw new Error("inline_reply_threads: only available inside an Inline chat")
      const cfg = configRuntime.current() as OpenClawConfig

      return await withInlineFollowClient({
        cfg,
        accountId: ctx.agentAccountId ?? null,
        fn: async (client, accountId) => {
          const groupId = await resolveInlineSettingsChatId(client, target)
          if (action === "status") {
            return jsonResult({ ok: true, chatId: groupId, mode: resolveCurrentMode({ cfg, accountId, groupId }) })
          }
          const committed = await configRuntime.mutateConfigFile({
            afterWrite: INLINE_LIVE_CONFIG_WRITE_AFTER_WRITE,
            mutate: (draft) => {
              setGroupMode({ draft, accountId, groupId, mode: action === "reset" ? "inherit" : action })
            },
          })
          return jsonResult({
            ok: true,
            chatId: groupId,
            mode: resolveCurrentMode({ cfg: committed.nextConfig as OpenClawConfig, accountId, groupId }),
          })
        },
      })
    },
  } as AnyAgentTool
}
