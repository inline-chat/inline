import { Cause } from "effect"
import { redactString, redactValue } from "@in/server/utils/log"

type DiagnosticCode = string | number | boolean
const MAX_REASONS = 8
const MAX_DIAGNOSTIC_TEXT_LENGTH = 128

export interface EffectCauseReasonDiagnostic {
  readonly kind: "Fail" | "Die" | "Interrupt"
  readonly errorType?: string | undefined
  readonly errorCode?: DiagnosticCode | undefined
}

export interface EffectCauseDiagnostic {
  readonly error: Error
  readonly metadata: {
    readonly reasonCount: number
    readonly reasons: readonly EffectCauseReasonDiagnostic[]
  }
}

const asRecord = (value: unknown): Record<string, unknown> | undefined =>
  typeof value === "object" && value !== null
    ? value as Record<string, unknown>
    : undefined

const boundedDiagnosticText = (value: string): string =>
  redactString(value).slice(0, MAX_DIAGNOSTIC_TEXT_LENGTH)

const diagnosticType = (value: unknown): string => {
  if (value instanceof Error && value.name) return boundedDiagnosticText(value.name)

  const record = asRecord(value)
  if (typeof record?.["_tag"] === "string") {
    return boundedDiagnosticText(record["_tag"])
  }

  const constructorName = record?.constructor?.name
  if (constructorName && constructorName !== "Object") {
    return boundedDiagnosticText(constructorName)
  }

  return typeof value
}

const diagnosticCode = (value: unknown): DiagnosticCode | undefined => {
  const record = asRecord(value)
  const code = record?.["code"] ??
    record?.["statusCode"] ??
    record?.["status"]
  if (typeof code === "string") return boundedDiagnosticText(code)
  return typeof code === "number" || typeof code === "boolean"
    ? code
    : undefined
}

const syntheticError = (
  kind: "Fail" | "Die" | "Interrupt",
  value?: unknown,
): Error => {
  const type = value === undefined
    ? "Effect interruption"
    : diagnosticType(value)
  const error = new Error(`Effect ${kind}: ${type}`)
  error.name = value === undefined
    ? "EffectInterruptError"
    : type
  return error
}

const reportableError = (
  kind: "Fail" | "Die",
  value: unknown,
): Error => {
  if (!(value instanceof Error)) return syntheticError(kind, value)

  const redacted = redactValue(value) as Error
  // Preserve Bun's hidden source provenance instead of constructing a new
  // Error at this reporting boundary. The explicit Error prototype still
  // keeps the value recognizable to Sentry without retaining provider fields.
  const error = Object.create(Error.prototype) as Error
  Object.defineProperties(error, {
    name: { configurable: true, writable: true, value: redacted.name },
    message: { configurable: true, writable: true, value: redacted.message },
    stack: { configurable: true, writable: true, value: redacted.stack },
  })
  return error
}

/**
 * Projects Effect's opaque Cause model into one real exception for Sentry and
 * bounded structural metadata. Arbitrary typed-error objects are never
 * serialized because they may contain request or provider data.
 */
export const effectCauseDiagnostic = <E>(
  cause: Cause.Cause<E>,
): EffectCauseDiagnostic => {
  const reasons: EffectCauseReasonDiagnostic[] = []
  let error: Error | undefined

  const causeReasons = cause.reasons
  for (const reason of causeReasons.slice(0, MAX_REASONS)) {
    if (Cause.isFailReason(reason)) {
      const errorType = diagnosticType(reason.error)
      reasons.push({
        kind: "Fail",
        errorType,
        errorCode: diagnosticCode(reason.error),
      })
      error ??= reportableError("Fail", reason.error)
      continue
    }

    if (Cause.isDieReason(reason)) {
      const errorType = diagnosticType(reason.defect)
      reasons.push({
        kind: "Die",
        errorType,
        errorCode: diagnosticCode(reason.defect),
      })
      error ??= reportableError("Die", reason.defect)
      continue
    }

    reasons.push({ kind: "Interrupt" })
  }

  return {
    error: error ?? syntheticError("Interrupt"),
    metadata: {
      reasonCount: causeReasons.length,
      reasons,
    },
  }
}
