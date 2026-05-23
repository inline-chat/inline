import type { PluginRuntime } from "openclaw/plugin-sdk/core"

const runtimeKey = "__inlineOpenClawRuntime"

type InlineRuntimeGlobal = typeof globalThis & {
  [runtimeKey]?: PluginRuntime | null
}

function runtimeStore(): InlineRuntimeGlobal {
  return globalThis as InlineRuntimeGlobal
}

export function setInlineRuntime(next: PluginRuntime): void {
  runtimeStore()[runtimeKey] = next
}

export function getInlineRuntime(): PluginRuntime {
  const runtime = runtimeStore()[runtimeKey]
  if (!runtime) {
    throw new Error("Inline runtime not initialized")
  }
  return runtime
}
