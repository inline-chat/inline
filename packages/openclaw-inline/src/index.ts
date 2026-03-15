import type { AnyAgentTool, OpenClawPluginApi } from "openclaw/plugin-sdk"
import { emptyPluginConfigSchema } from "openclaw/plugin-sdk"
import { inlineChannelPlugin } from "./inline/channel.js"
import { createInlineMessageTools } from "./inline/message-tools.js"
import { createInlineMembersTool } from "./inline/members-tool.js"
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
    api.registerTool((ctx) => createInlineMessageTools(ctx) as AnyAgentTool[], {
      names: ["inline_nudge", "inline_forward"],
    })
  },
}

export default plugin
