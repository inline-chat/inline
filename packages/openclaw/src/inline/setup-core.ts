import type { ChannelSetupAdapter } from "openclaw/plugin-sdk/setup"
import { createEnvPatchedAccountSetupAdapter } from "openclaw/plugin-sdk/setup"

const channel = "inline" as const

export const INLINE_TOKEN_HELP_LINES = [
  "1) Open Inline and generate a bot token for your workspace/account",
  "2) Copy the token",
  "3) Paste it here, or set INLINE_TOKEN in your environment",
  "Docs: https://inline.chat/docs/openclaw",
  "Website: https://openclaw.ai",
]

export const inlineSetupAdapter: ChannelSetupAdapter = createEnvPatchedAccountSetupAdapter({
  channelKey: channel,
  defaultAccountOnlyEnvError: "INLINE_TOKEN can only be used for the default account.",
  missingCredentialError: "Inline requires token or --token-file (or --use-env).",
  hasCredentials: (input) => Boolean(input.token || input.tokenFile),
  buildPatch: (input) =>
    input.tokenFile ? { tokenFile: input.tokenFile } : input.token ? { token: input.token } : {},
})
