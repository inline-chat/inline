import type { ChannelSetupWizard } from "openclaw/plugin-sdk/setup"
import {
  DEFAULT_ACCOUNT_ID,
  setSetupChannelEnabled,
} from "openclaw/plugin-sdk/setup"
import { listInlineAccountIds, resolveInlineAccount } from "./accounts.js"
import { INLINE_TOKEN_HELP_LINES, inlineSetupAdapter } from "./setup-core.js"

const channel = "inline" as const

export const inlineSetupWizard: ChannelSetupWizard = {
  channel,
  status: {
    configuredLabel: "configured",
    unconfiguredLabel: "needs token",
    configuredHint: "configured",
    unconfiguredHint: "recommended",
    configuredScore: 1,
    unconfiguredScore: 10,
    resolveConfigured: ({ cfg }) =>
      listInlineAccountIds(cfg).some((accountId) =>
        resolveInlineAccount({ cfg, accountId }).configured,
      ),
  },
  credentials: [
    {
      inputKey: "token",
      providerHint: channel,
      credentialLabel: "Inline token",
      preferredEnvVar: "INLINE_TOKEN",
      helpTitle: "Inline token",
      helpLines: INLINE_TOKEN_HELP_LINES,
      envPrompt: "INLINE_TOKEN detected. Use env var?",
      keepPrompt: "Inline token already configured. Keep it?",
      inputPrompt: "Enter Inline token",
      allowEnv: ({ accountId }) => accountId === DEFAULT_ACCOUNT_ID,
      inspect: ({ cfg, accountId }) => {
        const resolved = resolveInlineAccount({ cfg, accountId })
        const hasConfiguredValue = Boolean(
          (resolved.config.token ?? "").trim() || (resolved.config.tokenFile ?? "").trim(),
        )
        const resolvedValue = resolved.token?.trim()
        const envValue = accountId === DEFAULT_ACCOUNT_ID ? process.env.INLINE_TOKEN?.trim() : undefined
        return {
          accountConfigured: resolved.configured || hasConfiguredValue,
          hasConfiguredValue,
          ...(resolvedValue ? { resolvedValue } : {}),
          ...(envValue ? { envValue } : {}),
        }
      },
    },
  ],
  disable: (cfg) => setSetupChannelEnabled(cfg, channel, false),
}

export { inlineSetupAdapter }
