type RecordValue = Record<string, unknown>

const isRecord = (value: unknown): value is RecordValue => typeof value === "object" && value !== null

export type ApnFailureSummary = {
  status?: number
  reason?: string
  timestamp?: number
  errorCode?: string
  errorMessage?: string
}

// These are common per-device failures that are expected in production (uninstalls, expired tokens, app swaps).
const suppressedReasons = new Set(["BadDeviceToken", "Unregistered", "DeviceTokenNotForTopic", "TopicDisallowed"])

export const summarizeApnFailure = (failure: unknown): ApnFailureSummary => {
  if (!isRecord(failure)) return {}

  const status = typeof failure["status"] === "number" ? failure["status"] : undefined

  let reason: string | undefined
  let timestamp: number | undefined
  let errorCode: string | undefined
  let errorMessage: string | undefined

  const response = failure["response"]
  if (isRecord(response)) {
    if (typeof response["reason"] === "string") reason = response["reason"]
    const rawTimestamp = response["timestamp"]
    if (typeof rawTimestamp === "number") {
      timestamp = rawTimestamp
    } else if (typeof rawTimestamp === "string") {
      const parsed = Number(rawTimestamp)
      if (Number.isFinite(parsed)) timestamp = parsed
    }
  }

  const error = failure["error"]
  if (isRecord(error)) {
    if (!reason && typeof error["reason"] === "string") reason = error["reason"]
    if (typeof error["code"] === "string") errorCode = error["code"]
    if (typeof error["message"] === "string") errorMessage = error["message"]
  }

  return { status, reason, timestamp, errorCode, errorMessage }
}

export const isSuppressedApnFailure = (summary: ApnFailureSummary): boolean => {
  if (summary.status === 410) return true
  if (summary.reason && suppressedReasons.has(summary.reason)) return true
  return false
}

export const shouldInvalidateTokenForApnFailure = (summary: ApnFailureSummary): boolean => {
  if (summary.status === 410) return true
  if (!summary.reason) return false
  return suppressedReasons.has(summary.reason)
}

