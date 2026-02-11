import { readFileSync } from "node:fs"

let cached: string | null = null

// Best-effort. Used for ConnectionInit.clientVersion.
export const getSdkVersion = (): string => {
  if (cached) return cached

  try {
    // This file compiles to `dist/sdk/sdk-version.js`, so `../../package.json`
    // resolves to the published package's root package.json.
    const pkgUrl = new URL("../../package.json", import.meta.url)
    const raw = readFileSync(pkgUrl, "utf8")
    const parsed: unknown = JSON.parse(raw)
    if (typeof parsed === "object" && parsed !== null && "version" in parsed && typeof (parsed as any).version === "string") {
      const version = (parsed as any).version as string
      cached = version
      return version
    }
  } catch {
    // ignore
  }

  cached = "unknown"
  return cached
}
