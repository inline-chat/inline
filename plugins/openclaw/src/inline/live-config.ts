import type { OpenClawConfig } from "openclaw/plugin-sdk/core"

// Settings changed from chat (/threads, inline_reply_threads, the settings
// sheet) are written with `afterWrite: none` so the gateway doesn't restart the
// Inline channel mid-turn. The host then keeps serving its old runtime snapshot,
// so the plugin remembers what it committed and prefers it until the host's
// snapshot itself changes (a reload or restart that already includes the write).
//
// Each plugin entry is bundled separately, so the store lives on globalThis.
const STORE_KEY = Symbol.for("inline-openclaw.liveConfig.v1")

type InlineLiveConfigEntry = {
  config: OpenClawConfig
  hostSnapshot: unknown
}

type InlineLiveConfigStore = { entry: InlineLiveConfigEntry | null }

function store(): InlineLiveConfigStore {
  const root = globalThis as Record<symbol, unknown>
  let value = root[STORE_KEY] as InlineLiveConfigStore | undefined
  if (!value) {
    value = { entry: null }
    root[STORE_KEY] = value
  }
  return value
}

export const INLINE_LIVE_CONFIG_WRITE_AFTER_WRITE = {
  mode: "none",
  reason: "Inline applies chat settings in-process without restarting the channel.",
} as const

type InlineConfigRuntime = {
  current: () => unknown
  mutateConfigFile: (params: {
    afterWrite: typeof INLINE_LIVE_CONFIG_WRITE_AFTER_WRITE
    mutate: (draft: OpenClawConfig) => void
  }) => Promise<{ nextConfig: unknown }>
}

/** Writes a chat setting without a reload and makes it visible to this process. */
export async function mutateInlineLiveConfig(
  configRuntime: InlineConfigRuntime,
  mutate: (draft: OpenClawConfig) => void,
): Promise<OpenClawConfig> {
  const hostSnapshot = configRuntime.current()
  const committed = await configRuntime.mutateConfigFile({
    afterWrite: INLINE_LIVE_CONFIG_WRITE_AFTER_WRITE,
    mutate,
  })
  const config = committed.nextConfig as OpenClawConfig
  store().entry = { config, hostSnapshot }
  return config
}

/** The config to act on: the last chat write until the host snapshot moves on. */
export function resolveInlineLiveConfig<T>(hostSnapshot: T): T | OpenClawConfig {
  const entry = store().entry
  if (entry && entry.hostSnapshot === hostSnapshot) return entry.config
  return hostSnapshot
}

export function resetInlineLiveConfigForTest(): void {
  store().entry = null
}
