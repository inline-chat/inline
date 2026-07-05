import type { ChannelPlugin } from "openclaw/plugin-sdk/core"
import { inlineSetupAdapter } from "./setup-core.js"
import { inlineSetupWizard } from "./setup-surface.js"
import { inlineDoctor } from "./doctor.js"
import {
  INLINE_CHANNEL,
  inlineConfigAdapter,
  inlineConfigSchema,
  inlineMeta,
} from "./shared.js"
import { inlineSecrets } from "./secret-contract.js"
import { inlineSecurityAdapter } from "./security.js"

// Keep setup-only loads narrow: this module intentionally avoids importing the
// realtime monitor, outbound tools, media runtime, and gateway hooks.
export const inlineSetupPlugin: ChannelPlugin = {
  id: INLINE_CHANNEL,
  meta: inlineMeta,
  capabilities: {
    chatTypes: ["direct", "group"],
    media: true,
    reactions: true,
    edit: true,
    reply: true,
    groupManagement: true,
    threads: true,
    nativeCommands: true,
    blockStreaming: true,
  },
  streaming: {
    blockStreamingCoalesceDefaults: { minChars: 1500, idleMs: 1000 },
  },
  commands: {
    nativeCommandsAutoEnabled: true,
    nativeSkillsAutoEnabled: true,
  },
  reload: { configPrefixes: ["channels.inline"] },
  configSchema: inlineConfigSchema,
  setup: inlineSetupAdapter,
  setupWizard: inlineSetupWizard,
  doctor: inlineDoctor,
  secrets: inlineSecrets,
  config: inlineConfigAdapter,
  security: inlineSecurityAdapter,
}
