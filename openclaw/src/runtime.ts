import type { PluginRuntime } from "openclaw/plugin-sdk/core"
import { createPluginRuntimeStore } from "openclaw/plugin-sdk/runtime-store"

const {
  setRuntime: setInlineRuntime,
  clearRuntime: clearInlineRuntime,
  tryGetRuntime: getOptionalInlineRuntime,
  getRuntime: getInlineRuntime,
} = createPluginRuntimeStore<PluginRuntime>({
  pluginId: "inline",
  errorMessage: "Inline runtime not initialized",
})

export {
  clearInlineRuntime,
  getInlineRuntime,
  getOptionalInlineRuntime,
  setInlineRuntime,
}
