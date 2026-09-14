// Keep the bundled channel entry's default import light. Runtime/discovery
// paths load the full channel plugin only when OpenClaw asks for it.
import { inlineChannelPlugin as baseInlineChannelPlugin } from "./inline/channel.js"
import { instrumentOpenClawChannelPlugin } from "./telemetry.js"

export const inlineChannelPlugin = instrumentOpenClawChannelPlugin(baseInlineChannelPlugin)
