import {
  collectSimpleChannelFieldAssignments,
  getChannelSurface,
  type ResolverContext,
  type SecretDefaults,
  type SecretTargetRegistryEntry,
} from "openclaw/plugin-sdk/channel-secret-basic-runtime"

export const secretTargetRegistryEntries: SecretTargetRegistryEntry[] = [
  {
    id: "channels.inline.accounts.*.token",
    targetType: "channels.inline.accounts.*.token",
    configFile: "openclaw.json",
    pathPattern: "channels.inline.accounts.*.token",
    secretShape: "secret_input",
    expectedResolvedValue: "string",
    includeInPlan: true,
    includeInConfigure: true,
    includeInAudit: true,
  },
  {
    id: "channels.inline.token",
    targetType: "channels.inline.token",
    configFile: "openclaw.json",
    pathPattern: "channels.inline.token",
    secretShape: "secret_input",
    expectedResolvedValue: "string",
    includeInPlan: true,
    includeInConfigure: true,
    includeInAudit: true,
  },
]

export function collectRuntimeConfigAssignments(params: {
  config: { channels?: Record<string, unknown> }
  defaults?: SecretDefaults
  context: ResolverContext
}): void {
  const resolved = getChannelSurface(params.config, "inline")
  if (!resolved) {
    return
  }

  collectSimpleChannelFieldAssignments({
    channelKey: "inline",
    field: "token",
    channel: resolved.channel,
    surface: resolved.surface,
    defaults: params.defaults,
    context: params.context,
    topInactiveReason: "no enabled Inline account inherits this top-level token.",
    accountInactiveReason: "Inline account is disabled.",
  })
}

export const channelSecrets = {
  secretTargetRegistryEntries,
  collectRuntimeConfigAssignments,
}

export const inlineSecrets = channelSecrets
