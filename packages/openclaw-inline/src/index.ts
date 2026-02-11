import type { OpenClawPluginApi } from "openclaw/plugin-sdk"
import { emptyPluginConfigSchema } from "openclaw/plugin-sdk"
import { inlineChannelPlugin } from "./inline/channel.js"
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
  id: "openclaw-inline",
  name: "Inline",
  description: "Inline Chat channel plugin (realtime RPC)",
  configSchema: emptyPluginConfigSchema(),
  register(api: OpenClawPluginApi) {
    setInlineRuntime(api.runtime)
    api.registerChannel({ plugin: inlineChannelPlugin })
  },
}

export default plugin
