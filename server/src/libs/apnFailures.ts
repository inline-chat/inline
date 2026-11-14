type RecordValue = Record<string, unknown>

const isRecord = (value: unknown): value is RecordValue => typeof value === "object" && value !== null
const isError = (value: unknown): value is Error =>
  value instanceof Error ||
  (isRecord(value) && typeof value["message"] === "string" && typeof value["stack"] === "string")

const extractErrorDetails = (value: unknown): { errorCode?: string; errorMessage?: string } => {
  if (typeof value === "string") return { errorMessage: value }
  if (isError(value)) {
    const code =
      isRecord(value) && typeof value["code"] === "string" ? (value["code"] as string) : undefined
    return { errorCode: code, errorMessage: value.message }
  }
  if (!isRecord(value)) return {}

  const errorCode = typeof value["code"] === "string" ? value["code"] : undefined
  const errorMessage = typeof value["message"] === "string" ? value["message"] : undefined
  return { errorCode, errorMessage }
}

export type ApnFailureSummary = {
  status?: number
  reason?: string
  timestamp?: number
  errorCode?: string
  errorMessage?: string
}

// Per-device rejections that are expected in production (uninstalls, expired tokens, a debug build's
// token registered with this server). They prove the token is dead. Provider-wide failures such as
// TopicDisallowed or InvalidProviderToken are configuration errors and never release a token.
const suppressedReasons = new Set(["BadDeviceToken", "Unregistered", "DeviceTokenNotForTopic"])

export const summarizeApnFailure = (failure: unknown): ApnFailureSummary => {
  if (typeof failure === "string") {
    return { errorMessage: failure }
  }

  if (isError(failure)) {
    const { errorCode, errorMessage } = extractErrorDetails(failure)
    return { errorCode, errorMessage }
  }

  if (!isRecord(failure)) return {}

  const status = typeof failure["status"] === "number" ? failure["status"] : undefined

  let reason: string | undefined
  let timestamp: number | undefined
  let errorCode: string | undefined
  let errorMessage: string | undefined

  if (typeof failure["reason"] === "string") reason = failure["reason"]
  const rawTimestamp = failure["timestamp"]
  if (typeof rawTimestamp === "number") {
    timestamp = rawTimestamp
  } else if (typeof rawTimestamp === "string") {
    const parsed = Number(rawTimestamp)
    if (Number.isFinite(parsed)) timestamp = parsed
  }

  const response = failure["response"]
  if (isRecord(response)) {
    if (typeof response["reason"] === "string") reason = response["reason"]
    const responseTimestamp = response["timestamp"]
    if (typeof responseTimestamp === "number") {
      timestamp = responseTimestamp
    } else if (typeof responseTimestamp === "string") {
      const parsed = Number(responseTimestamp)
      if (Number.isFinite(parsed)) timestamp = parsed
    }
  }

  const error = failure["error"]
  if (isRecord(error) && !reason && typeof error["reason"] === "string") reason = error["reason"]
  const extracted = extractErrorDetails(error)
  if (extracted.errorCode) errorCode = extracted.errorCode
  if (extracted.errorMessage) errorMessage = extracted.errorMessage

  return { status, reason, timestamp, errorCode, errorMessage }
}

export const isSuppressedApnFailure = (summary: ApnFailureSummary): boolean => {
  if (summary.status === 410) return true
  if (summary.reason && suppressedReasons.has(summary.reason)) return true
  return false
}
