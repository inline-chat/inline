import type { ChannelSetupAdapter } from "openclaw/plugin-sdk/setup"
import { createEnvPatchedAccountSetupAdapter } from "openclaw/plugin-sdk/setup"
import { resolveInlineEnvToken } from "./accounts.js"

const channel = "inline" as const

export const INLINE_TOKEN_HELP_LINES = [
  "1) In Inline, create a bot from Settings -> Bots or with `inline bots create`.",
  "2) Copy the bot token shown after creation, or reveal it with `inline bots reveal-token`.",
  "3) Paste it here, or set INLINE_TOKEN in your environment.",
  "INLINE_BOT_TOKEN is also accepted as a compatibility alias.",
  "Bot guide: https://inline.chat/docs/creating-a-bot",
  "Docs: https://inline.chat/docs/openclaw",
  "Website: https://openclaw.ai",
]

export function resolveInlineSetupEnvToken(): string | undefined {
  return resolveInlineEnvToken() ?? undefined
}

export const inlineSetupAdapter: ChannelSetupAdapter = createEnvPatchedAccountSetupAdapter({
  channelKey: channel,
  defaultAccountOnlyEnvError: "INLINE_TOKEN/INLINE_BOT_TOKEN can only be used for the default account.",
  missingCredentialError:
    "Inline requires token or --token-file (or --use-env with INLINE_TOKEN/INLINE_BOT_TOKEN).",
  hasCredentials: (input) => Boolean(input.token || input.tokenFile),
  buildPatch: (input) =>
    input.tokenFile ? { tokenFile: input.tokenFile } : input.token ? { token: input.token } : {},
})
