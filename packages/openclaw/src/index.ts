import {
  defineBundledChannelEntry,
  loadBundledEntryExportSync,
  type OpenClawPluginApi,
} from "openclaw/plugin-sdk/channel-entry-contract"

function registerInlinePluginFull(api: OpenClawPluginApi): void {
  const register = loadBundledEntryExportSync<(api: OpenClawPluginApi) => void>(import.meta.url, {
    specifier: "./runtime-register-api.js",
    exportName: "registerInlinePluginFull",
  })
  register(api)
}

export default defineBundledChannelEntry({
  id: "inline",
  name: "Inline",
  description: "Inline channel plugin for OpenClaw bots.",
  importMetaUrl: import.meta.url,
  plugin: {
    specifier: "./channel-plugin-api.js",
    exportName: "inlineChannelPlugin",
  },
  secrets: {
    specifier: "./secret-contract-api.js",
    exportName: "channelSecrets",
  },
  runtime: {
    specifier: "./runtime-setter-api.js",
    exportName: "setInlineRuntime",
  },
  accountInspect: {
    specifier: "./account-inspect-api.js",
    exportName: "inspectInlineReadOnlyAccount",
  },
  registerFull: registerInlinePluginFull,
})
