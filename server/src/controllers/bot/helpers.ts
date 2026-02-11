import { t, type TSchema } from "elysia"

export const TApiEnvelope = <T extends TSchema>(type: T) => {
  const success = t.Object({ ok: t.Literal(true), result: type })
  const failure = t.Object({
    ok: t.Literal(false),
    // Compact envelope for bot HTTP API.
    // We keep `error` as an optional machine-readable string, but prefer `error_code` + `description`.
    error: t.Optional(t.String()),
    error_code: t.Number(),
    description: t.String(),
  })

  return t.Union([success, failure])
}

export const normalizeInputId = (value: string | number | undefined): number | undefined => {
  if (value === undefined) return undefined
  if (typeof value === "number") return Number.isSafeInteger(value) ? value : undefined

  const trimmed = value.trim()
  if (!trimmed) return undefined

  // Require the whole string to be an integer (no truncation like parseInt("123abc")).
  if (!/^[+-]?\d+$/.test(trimmed)) return undefined

  const n = Number(trimmed)
  return Number.isSafeInteger(n) ? n : undefined
}
