import { readFileSync } from "node:fs"

let cached: string | undefined | null = null

// Best-effort. Used for ConnectionInit.clientVersion.
export const getSdkVersion = (): string | undefined => {
  if (cached !== null) return cached

  try {
    // This file compiles to `dist/sdk/sdk-version.js`, so `../../package.json`
    // resolves to the published package's root package.json.
    const pkgUrl = new URL("../../package.json", import.meta.url)
    const raw = readFileSync(pkgUrl, "utf8")
    const parsed: unknown = JSON.parse(raw)
    if (typeof parsed === "object" && parsed !== null && "version" in parsed && typeof (parsed as any).version === "string") {
      const version = ((parsed as any).version as string).trim()
      if (!version) {
        cached = undefined
        return cached
      }
      cached = version
      return version
    }
  } catch {
    // ignore
  }

  cached = undefined
  return cached
}
