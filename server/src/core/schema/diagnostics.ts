import { Option, Schema } from "effect"

export const MAX_DIAGNOSTIC_TEXT_LENGTH = 256

/**
 * A bounded, non-empty diagnostic value safe to attach to structured reports.
 *
 * This is intentionally not a public wire schema. It prevents request-derived
 * metadata from creating unbounded log or telemetry attributes.
 */
export const DiagnosticText = Schema.Trim.check(
  Schema.isMinLength(1),
  Schema.isMaxLength(MAX_DIAGNOSTIC_TEXT_LENGTH),
).pipe(Schema.brand("DiagnosticText"))

export type DiagnosticText = typeof DiagnosticText.Type

const decodeDiagnosticText = Schema.decodeUnknownOption(DiagnosticText)

export const toDiagnosticText = (
  input: unknown,
): DiagnosticText | undefined => {
  if (typeof input !== "string") {
    return undefined
  }

  const trimmed = input.trim()
  if (trimmed.length === 0) {
    return undefined
  }

  const bounded =
    trimmed.length <= MAX_DIAGNOSTIC_TEXT_LENGTH
      ? trimmed
      : `${trimmed.slice(0, MAX_DIAGNOSTIC_TEXT_LENGTH - 3)}...`

  return Option.getOrUndefined(
    decodeDiagnosticText(bounded),
  )
}
