import type { AnyAgentTool, OpenClawPluginApi } from "openclaw/plugin-sdk/plugin-entry"
import { inlineChannelPlugin } from "./inline/channel.js"
import { createInlineMessageTools } from "./inline/message-tools.js"
import { createInlineMembersTool } from "./inline/members-tool.js"
import { sanitizeInlineOutgoingText } from "./inline/message-formatting.js"
import { createInlineProfileTool } from "./inline/profile-tool.js"
import { createInlineBotCommandsTool } from "./inline/bot-commands-tool.js"
import { syncInlineNativeCommands } from "./inline/bot-commands-sync.js"
import { emptyPluginConfigSchema } from "./openclaw-compat.js"
import { setInlineRuntime } from "./runtime.js"

const plugin: {
  id: string
  name: string
  description: string
  // Keep this intentionally loose to avoid leaking OpenClaw internal type paths
  // into our emitted .d.ts (TS2742).
  configSchema: unknown
  register: (api: OpenClawPluginApi) => void
} = {
  id: "inline",
  name: "Inline",
  description: "Inline Chat channel plugin (realtime RPC)",
  configSchema: emptyPluginConfigSchema(),
  register(api: OpenClawPluginApi) {
    setInlineRuntime(api.runtime)
    api.registerChannel({ plugin: inlineChannelPlugin })
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
    api.on("message_sending", (event, ctx) => {
      if (ctx.channelId !== "inline") return
      const content = sanitizeInlineOutgoingText(event.content)
      if (content === event.content) return
      return { content }
    })
    api.on("gateway_start", async () => {
      await syncInlineNativeCommands({
        cfg: api.config,
        logger: api.logger,
      })
    })
  },
}

export default plugin
