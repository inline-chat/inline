import type {
  ChannelAccountSnapshot,
  ChannelStatusIssue,
} from "openclaw/plugin-sdk/channel-contract"
import { asString, isRecord } from "openclaw/plugin-sdk/status-helpers"

type InlineProbeSummary = {
  ok?: boolean
  error?: string
}

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
    if (lastError) {
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
  }
  return issues
}
