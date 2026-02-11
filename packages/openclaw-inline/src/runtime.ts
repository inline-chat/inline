import type { PluginRuntime } from "openclaw/plugin-sdk"

let runtime: PluginRuntime | null = null

export function setInlineRuntime(next: PluginRuntime): void {
  runtime = next
}

export function getInlineRuntime(): PluginRuntime {
  if (!runtime) {
    throw new Error("Inline runtime not initialized")
  }
  return runtime
}

