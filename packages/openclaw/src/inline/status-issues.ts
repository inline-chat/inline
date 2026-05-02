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

function looksLikeTransientConnectionNotice(text: string): boolean {
  return (
    text.startsWith("WebSocket reconnect scheduled ") ||
    text.startsWith("WebSocket closed ") ||
    text.startsWith("WebSocket error: ") ||
    text.startsWith("Protocol reconnect scheduled ") ||
    text.startsWith("Ping timeout, reconnecting ") ||
    text.startsWith("Failed to send ping") ||
    text.startsWith("Failed to send RPC request; waiting for reconnect")
  )
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
    if (!configured) {
      issues.push({
        channel: "inline",
        accountId,
        kind: "config",
        message: "Inline account is enabled but missing token/tokenFile.",
        fix: "Set channels.inline.token (or tokenFile), then restart the gateway.",
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

    const lastError = asString(entry.lastError)
    if (lastError && !looksLikeTransientConnectionNotice(lastError)) {
      issues.push({
        channel: "inline",
        accountId,
        kind: looksLikeAuthError(lastError) ? "auth" : "runtime",
        message: `Inline runtime error: ${lastError}`,
        fix: "Verify token/baseUrl and restart the gateway.",
      })
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
