/**
 * Test helper: evaluates a token or theme source file without the StyleX
 * compiler, to read the values it declares. Only for files whose shape is
 * imports plus `export const x = stylex.defineVars({...})` or
 * `stylex.createTheme(group, {...})` with literal values, as ours are.
 */

import { readFileSync } from "node:fs"

export type DeclaredValue = string | Record<string, string | null>

export type Declared = {
  kind: "defineVars" | "createTheme"
  group?: string
  values: Record<string, DeclaredValue>
}

export function readStylexDeclarations(path: string): Record<string, Declared> {
  const source = readFileSync(path, "utf8")
  const body = source
    .replace(/^import[^\n]*\n/gm, "")
    .replace(/export const (\w+) = stylex\./g, "out.$1 = stylex.")
  const out: Record<string, Declared> = {}
  const groups = ["color", "themeColor", "font", "chatText", "density"]
  const stylex = {
    defineVars: (values: Record<string, DeclaredValue>) => ({ kind: "defineVars", values }),
    createTheme: (group: { __group: string }, values: Record<string, DeclaredValue>) => ({
      kind: "createTheme",
      group: group.__group,
      values,
    }),
  }
  // Group references (`color`, `themeColor`, ...) resolve to their names.
  new Function("stylex", "out", ...groups, body)(stylex, out, ...groups.map((name) => ({ __group: name })))
  return out
}

/** The plain (no media query) value of a declared token. */
export const defaultValue = (value: DeclaredValue | undefined): string | undefined =>
  value === undefined ? undefined : typeof value === "string" ? value : (value.default ?? undefined)

/**
 * The style objects a view file declares with `const <name> = stylex.create({...})`,
 * evaluated without the compiler. Token references read as `var(--<group>-<key>)`,
 * keyframes as `keyframes(<name>)`. Dynamic styles (functions) come back as
 * functions. For tests that pin a view's layout rules (a dialog's centering,
 * a toast's placement) where no layout engine is available.
 */
export function readStylexStyles(path: string, name = "styles"): Record<string, Record<string, unknown>> {
  const source = readFileSync(path, "utf8")
  const start = source.indexOf(`const ${name} = stylex.create(`)
  if (start < 0) throw new Error(`No "const ${name} = stylex.create(" in ${path}`)
  const open = source.indexOf("(", start)
  let depth = 0
  let end = open
  for (; end < source.length; end++) {
    const char = source[end]
    if (char === "(") depth++
    else if (char === ")" && --depth === 0) break
  }
  const body = source.slice(open + 1, end)
  const tokenGroups = new Set<string>()
  for (const match of source.matchAll(/import\s*\{([^}]*)\}\s*from\s*"[^"]*\.stylex"/g)) {
    for (const part of (match[1] ?? "").split(",")) {
      const local = part.trim().split(/\s+as\s+/).pop()?.trim()
      if (local) tokenGroups.add(local)
    }
  }
  const keyframes = [...source.matchAll(/const (\w+) = stylex\.keyframes\(/g)].map((match) => match[1] ?? "")
  const group = (groupName: string) =>
    new Proxy({}, { get: (_target, key) => (typeof key === "string" ? `var(--${groupName}-${key})` : undefined) })
  const names = [...tokenGroups, ...keyframes]
  const values = [...[...tokenGroups].map(group), ...keyframes.map((keyframe) => `keyframes(${keyframe})`)]
  return new Function(...names, `return (${body})`)(...values) as Record<string, Record<string, unknown>>
}

/** Physical properties a view must not use (logical properties only). */
export const PHYSICAL_PROPERTIES: readonly string[] = [
  "width",
  "height",
  "minWidth",
  "minHeight",
  "maxWidth",
  "maxHeight",
  "left",
  "right",
  "top",
  "bottom",
  "marginTop",
  "marginBottom",
  "marginLeft",
  "marginRight",
  "paddingTop",
  "paddingBottom",
  "paddingLeft",
  "paddingRight",
]
