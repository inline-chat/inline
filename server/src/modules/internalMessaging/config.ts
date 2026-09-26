/** Explicit transport configuration, never a guess based on live server count. */
export function distributedRealtimeConfig(env: Readonly<Record<string, string | undefined>> = process.env) {
  const url = env["REDIS_URL"]?.trim() || env["VALKEY_URL"]?.trim() || undefined
  const setting = env["REALTIME_DISTRIBUTED"]
  if (setting !== undefined && setting !== "0" && setting !== "1") {
    throw new Error("REALTIME_DISTRIBUTED must be 0 or 1")
  }
  const enabled = setting === "1" || (setting === undefined && url !== undefined)
  return { enabled, url: enabled ? url : undefined }
}

export const isDistributedRealtimeEnabled = (): boolean => distributedRealtimeConfig().enabled
