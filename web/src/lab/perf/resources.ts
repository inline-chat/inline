/**
 * Which scripts count as the initial UI JavaScript: same-origin scripts whose
 * fetch started before the signed-in shell painted, without worker bundles,
 * the SQLite WASM and its workers, and code only the demo or the labs build
 * load. Pure; tested in `resources.test.ts`.
 */

export type ResourceFact = {
  name: string
  initiatorType: string
  startTime: number
  transferSize: number
  encodedBodySize: number
  decodedBodySize: number
}

export type Exclusion = { name: string; reason: string }

/** Path patterns that are not UI code, with the reason. Vite names chunks after their entry file. */
const EXCLUDED: readonly (readonly [RegExp, string])[] = [
  [/\.worker-[^/]*\.js$/, "worker bundle"],
  [/\/sqlite3-[^/]*\.js$/, "SQLite worker"],
  [/\/sw\.js$/, "service worker"],
  [/\/connect-demo-[^/]*\.js$/, "demo only (not in production)"],
  [/\/demo\.worker-[^/]*\.js$/, "demo only (not in production)"],
  [/\/dev-snapshot-[^/]*\.js$/, "labs build only (__inlineApp)"],
  [/\/@vite\/|\/node_modules\/\.vite\//, "development server"],
]

export const classifyInitialScripts = (
  entries: readonly ResourceFact[],
  shellPaintAt: number,
  origin: string,
): { counted: ResourceFact[]; excluded: Exclusion[] } => {
  const counted: ResourceFact[] = []
  const excluded: Exclusion[] = []
  for (const entry of entries) {
    let url: URL
    try {
      url = new URL(entry.name)
    } catch {
      continue
    }
    if (!/\.m?js$/.test(url.pathname)) continue
    if (url.origin !== origin) {
      excluded.push({ name: entry.name, reason: "other origin" })
      continue
    }
    if (entry.startTime >= shellPaintAt) continue
    const rule = EXCLUDED.find(([pattern]) => pattern.test(url.pathname))
    if (rule) {
      excluded.push({ name: entry.name, reason: rule[1] })
      continue
    }
    counted.push(entry)
  }
  return { counted, excluded }
}

/** The file part of a URL, for the report. */
export const fileName = (url: string): string => {
  try {
    return new URL(url).pathname.split("/").pop() || url
  } catch {
    return url
  }
}
