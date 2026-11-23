import { AsyncLocalStorage } from "node:async_hooks"

/**
 * Request-scoped SQLCommenter tags. PlanetScale Insights groups query load by
 * these (`tag:oauth_client:msgvault`), so a caller's database cost can be
 * attributed without reading parameters. Values are bounded labels, never
 * identities, tokens or user input that was not normalized first.
 */
const tags = new AsyncLocalStorage<string>()

const SAFE_VALUE = /^[a-z0-9._:-]{1,64}$/

/** Runs `operation` with every unprepared query it issues tagged with `values`. */
export const withQueryTags = <T>(values: Readonly<Record<string, string>>, operation: () => T): T => {
  const parts = Object.keys(values)
    .sort()
    .filter((key) => /^[a-z_]{1,32}$/.test(key) && SAFE_VALUE.test(values[key]!))
    .map((key) => `${key}='${values[key]}'`)
  const inherited = tags.getStore()
  const fragment = [inherited, ...parts].filter(Boolean).join(",")
  return fragment ? tags.run(fragment, operation) : operation()
}

/**
 * Adds the active tags to `query`. A trailing SQLCommenter comment is extended
 * in place, since Insights reads one comment; anything else gets its own.
 */
export const tagQuery = (query: string): string => {
  const fragment = tags.getStore()
  if (!fragment) return query
  const trimmed = query.trimEnd()
  if (trimmed.endsWith("'*/")) {
    const start = trimmed.lastIndexOf("/*")
    if (start >= 0 && trimmed.indexOf("*/", start) === trimmed.length - 2) {
      return `${trimmed.slice(0, -2)},${fragment}*/`
    }
  }
  return `${trimmed} /*${fragment}*/`
}
