import type {
  ChannelAccountSnapshot,
  ChannelStatusIssue,
} from "openclaw/plugin-sdk/channel-contract"
import { asString, isRecord } from "openclaw/plugin-sdk/status-helpers"

type InlineProbeSummary = {
  ok?: boolean
  error?: string
}

type InlineDiagnosticsSummary = {
  protocol?: {
    lastFailureAt?: number
    lastFailureReason?: string | undefined
    ping?: {
      lastTimeoutAt?: number
    }
  }
  transport?: {
    reconnectCount?: number
    lastReconnectCause?: string | undefined
  }
}

const RECENT_RUNTIME_ISSUE_MS = 30 * 60 * 1000
const INLINE_CONNECT_GRACE_MS = 120 * 1000

function readInlineProbeSummary(value: unknown): InlineProbeSummary {
  if (!isRecord(value)) {
    return {}
  }
  const summary: InlineProbeSummary = {}
  if (typeof value.ok === "boolean") {
    summary.ok = value.ok
  }
  const error = asString(value.error)
  if (error) {
    summary.error = error
  }
  return summary
}

function looksLikeAuthError(text: string): boolean {
  return /(401|403|unauth|forbidden|invalid token|token invalid|unauthorized)/i.test(text)
}

function readInlineDiagnosticsSummary(value: unknown): InlineDiagnosticsSummary {
  if (!isRecord(value)) {
    return {}
  }

  const protocolValue = isRecord(value.protocol) ? value.protocol : undefined
  const transportValue =
    (protocolValue && isRecord(protocolValue.transport) ? protocolValue.transport : undefined) ??
    (isRecord(value.transport) ? value.transport : undefined)
  const pingValue = protocolValue && isRecord(protocolValue.ping) ? protocolValue.ping : undefined

  return {
    ...(protocolValue
      ? {
          protocol: {
            ...(typeof protocolValue.lastFailureAt === "number"
              ? { lastFailureAt: protocolValue.lastFailureAt }
              : {}),
            ...(asString(protocolValue.lastFailureReason)
              ? { lastFailureReason: asString(protocolValue.lastFailureReason) }
              : {}),
            ...(pingValue && typeof pingValue.lastTimeoutAt === "number"
              ? {
                  ping: {
                    lastTimeoutAt: pingValue.lastTimeoutAt,
                  },
                }
              : {}),
          },
        }
      : {}),
    ...(transportValue
      ? {
          transport: {
            ...(typeof transportValue.reconnectCount === "number"
              ? { reconnectCount: transportValue.reconnectCount }
              : {}),
            ...(asString(transportValue.lastReconnectCause)
              ? { lastReconnectCause: asString(transportValue.lastReconnectCause) }
              : {}),
          },
        }
      : {}),
  }
}

function isRecentTimestamp(timestamp: number | undefined): boolean {
  if (typeof timestamp !== "number" || !Number.isFinite(timestamp) || timestamp <= 0) return false
  return Date.now() - timestamp <= RECENT_RUNTIME_ISSUE_MS
}

function asFiniteNumber(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null
}

export function collectInlineStatusIssues(accounts: ChannelAccountSnapshot[]): ChannelStatusIssue[] {
  const issues: ChannelStatusIssue[] = []
  for (const entry of accounts) {
    if (!isRecord(entry)) {
      continue
    }
    const accountId = asString(entry.accountId)
    if (!accountId) {
      continue
    }
    const enabled = entry.enabled !== false
    if (!enabled) {
      continue
    }
    const configured = entry.configured !== false
    const lastError = asString(entry.lastError) ?? ""
    if (!configured) {
      if (/duplicate inline bot token/i.test(lastError)) {
        issues.push({
          channel: "inline",
          accountId,
          kind: "config",
          message: lastError,
          fix: "Use a unique Inline bot token for each configured account, or disable/remove the duplicate account.",
        })
        continue
      }
      const tokenSource = asString(entry.tokenSource)
      const tokenConfigured = tokenSource && tokenSource !== "none"
      issues.push({
        channel: "inline",
        accountId,
        kind: "config",
        message: tokenConfigured
          ? "Inline account token is configured but unavailable."
          : "Inline account is enabled but missing token/tokenFile.",
        fix: tokenConfigured
          ? "Resolve the configured token SecretRef or switch to channels.inline.tokenFile, INLINE_TOKEN, or INLINE_BOT_TOKEN, then restart the gateway."
          : "Set channels.inline.token, channels.inline.tokenFile, INLINE_TOKEN, or INLINE_BOT_TOKEN, then restart the gateway.",
      })
      continue
    }

    const baseUrl = asString(entry.baseUrl)
    if (!baseUrl || baseUrl === "[missing]") {
      issues.push({
        channel: "inline",
        accountId,
        kind: "config",
        message: "Inline account is configured but baseUrl is missing.",
        fix: 'Set channels.inline.baseUrl (for example "https://api.inline.chat"), then restart the gateway.',
      })
    }

    if (lastError) {
      issues.push({
        channel: "inline",
        accountId,
        kind: looksLikeAuthError(lastError) ? "auth" : "runtime",
        message: `Inline runtime error: ${lastError}`,
        fix: "Verify token/baseUrl and restart the gateway.",
      })
    }

    if (entry.running === true && entry.connected === false) {
      const lastStartAt = asFiniteNumber(entry.lastStartAt)
      const withinStartupGrace =
        lastStartAt != null && Date.now() - lastStartAt < INLINE_CONNECT_GRACE_MS
      if (!withinStartupGrace) {
        issues.push({
          channel: "inline",
          accountId,
          kind: "runtime",
          message: "Inline realtime monitor is running but not connected.",
          fix: "Run channel status with probing or restart the gateway. Check Inline token/baseUrl, network reachability, and gateway logs if it persists.",
        })
      }
    }

    const probe = readInlineProbeSummary(entry.probe)
    if (probe.ok === false && probe.error) {
      issues.push({
        channel: "inline",
        accountId,
        kind: looksLikeAuthError(probe.error) ? "auth" : "runtime",
        message: `Inline probe failed: ${probe.error}`,
        fix: "Verify token/baseUrl connectivity, then re-run channel status.",
      })
    }

    const diagnostics = readInlineDiagnosticsSummary((entry as Record<string, unknown>).diagnostics)
    if (
      isRecentTimestamp(diagnostics.protocol?.lastFailureAt) &&
      (diagnostics.transport?.reconnectCount ?? 0) >= 3
    ) {
      issues.push({
        channel: "inline",
        accountId,
        kind: "runtime",
        message:
          `Inline connection is flapping (${diagnostics.transport?.reconnectCount ?? 0} reconnects). ` +
          `${diagnostics.protocol?.lastFailureReason ?? diagnostics.transport?.lastReconnectCause ?? "Recent reconnect failures detected."}`,
        fix: "Inspect gateway logs for websocket close/error details and verify Inline API/network stability.",
      })
    }

    if (isRecentTimestamp(diagnostics.protocol?.ping?.lastTimeoutAt)) {
      issues.push({
        channel: "inline",
        accountId,
        kind: "runtime",
        message: "Inline ping watchdog triggered a reconnect recently.",
        fix: "Check websocket latency/packet loss and compare last pong timing in the Inline diagnostics snapshot.",
      })
    }
  }
  return issues
}
