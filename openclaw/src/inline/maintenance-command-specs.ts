import type { OpenClawPluginCommandDefinition } from "openclaw/plugin-sdk/channel-entry-contract"

export const INLINE_SYNC_COMMAND_SPEC = {
  name: "inline-sync",
  nativeNames: { inline: "inline_sync" },
  nativeProgressMessages: { inline: "Syncing Inline commands and skills…" },
  description: "Resync Inline commands and skills",
  channels: ["inline"],
  acceptsArgs: false,
} satisfies Pick<
  OpenClawPluginCommandDefinition,
  | "name"
  | "nativeNames"
  | "nativeProgressMessages"
  | "description"
  | "channels"
  | "acceptsArgs"
>

export const INLINE_VERSION_COMMAND_SPEC = {
  name: "inline-version",
  nativeNames: { inline: "inline_version" },
  description: "Show Inline plugin and sync information",
  channels: ["inline"],
  acceptsArgs: false,
} satisfies Pick<
  OpenClawPluginCommandDefinition,
  "name" | "nativeNames" | "description" | "channels" | "acceptsArgs"
>

export function listInlineMaintenanceCommandSpecs() {
  return [INLINE_SYNC_COMMAND_SPEC, INLINE_VERSION_COMMAND_SPEC].map((spec) => ({
    name: spec.nativeNames.inline,
    description: spec.description,
    acceptsArgs: spec.acceptsArgs,
  }))
}
