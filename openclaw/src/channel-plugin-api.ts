// Keep the bundled channel entry's default import light. Runtime/discovery
// paths load the full channel plugin only when OpenClaw asks for it.
export { inlineChannelPlugin } from "./inline/channel.js"
