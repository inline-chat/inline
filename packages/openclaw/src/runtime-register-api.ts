import type { AnyAgentTool, OpenClawPluginApi } from "openclaw/plugin-sdk/channel-entry-contract"
import { createInlineMessageTools } from "./inline/message-tools.js"
import { createInlineMembersTool } from "./inline/members-tool.js"
import { createInlineParentContextTool } from "./inline/parent-context-tool.js"
import { sanitizeInlineOutgoingText } from "./inline/message-formatting.js"
import { sanitizeInlineVisibleText } from "./inline/outbound-sanitize.js"
import { createInlineProfileTool } from "./inline/profile-tool.js"
import { createInlineBotCommandsTool } from "./inline/bot-commands-tool.js"
import { syncInlineNativeCommands } from "./inline/bot-commands-sync.js"

export function registerInlinePluginFull(api: OpenClawPluginApi): void {
  api.registerTool((ctx) => createInlineMembersTool(ctx) as AnyAgentTool, {
    names: ["inline_members"],
  })
  api.registerTool((ctx) => createInlineProfileTool(ctx) as AnyAgentTool, {
    names: ["inline_update_profile"],
  })
  api.registerTool((ctx) => createInlineBotCommandsTool(ctx) as AnyAgentTool, {
    names: ["inline_bot_commands"],
  })
  api.registerTool((ctx) => createInlineMessageTools(ctx) as AnyAgentTool[], {
    names: ["inline_nudge", "inline_forward"],
  })
  api.registerTool((ctx) => createInlineParentContextTool(ctx) as AnyAgentTool, {
    names: ["inline_parent_context"],
  })
  api.on("message_sending", (event, ctx) => {
    if (ctx.channelId !== "inline") return
    const visible = sanitizeInlineVisibleText(event.content)
    if (visible.shouldSkip) {
      return {
        content: "",
        cancel: true,
        cancelReason: "suppressed_internal_context",
      }
    }
    const content = sanitizeInlineOutgoingText(visible.text)
    if (content === event.content) return
    return { content }
  })
  api.on("gateway_start", async () => {
    await syncInlineNativeCommands({
      cfg: api.config,
      logger: api.logger,
    })
  })
}
