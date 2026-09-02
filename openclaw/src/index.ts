import {
  defineBundledChannelEntry,
  loadBundledEntryExportSync,
  type OpenClawPluginApi,
} from "openclaw/plugin-sdk/channel-entry-contract"
import {
  instrumentOpenClawPluginApi,
  reportOpenClawRegistrationError,
} from "./telemetry.js"

function registerInlinePluginFull(api: OpenClawPluginApi): void {
  const register = loadBundledEntryExportSync<(api: OpenClawPluginApi) => void>(import.meta.url, {
    specifier: "./runtime-register-api.js",
    exportName: "registerInlinePluginFull",
  })
  try {
    register(instrumentOpenClawPluginApi(api))
  } catch (error) {
    reportOpenClawRegistrationError(error)
    throw error
  }
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
