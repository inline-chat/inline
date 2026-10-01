/** Explicit transport configuration, never a guess based on live server count. */
export function distributedRealtimeConfig(env: Readonly<Record<string, string | undefined>> = process.env) {
  const url = env["REDIS_URL"]?.trim() || env["VALKEY_URL"]?.trim() || undefined
  const configured = env["INLINE_REALTIME_DISTRIBUTED"]
  const legacy = env["REALTIME_DISTRIBUTED"]
  for (const [name, value] of [["INLINE_REALTIME_DISTRIBUTED", configured], ["REALTIME_DISTRIBUTED", legacy]]) {
    if (value !== undefined && value !== "0" && value !== "1") {
      throw new Error(`${name} must be 0 or 1`)
    }
  }
  if (configured !== undefined && legacy !== undefined && configured !== legacy) {
    throw new Error("INLINE_REALTIME_DISTRIBUTED and REALTIME_DISTRIBUTED must agree when both are set")
  }
  const setting = configured ?? legacy
  const enabled = setting === "1" || (setting === undefined && url !== undefined)
  return { enabled, url: enabled ? url : undefined }
}

export const isDistributedRealtimeEnabled = (): boolean => distributedRealtimeConfig().enabled
