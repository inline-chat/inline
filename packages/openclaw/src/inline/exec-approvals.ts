import { resolveApprovalApprovers } from "openclaw/plugin-sdk/approval-auth-runtime"
import {
  createChannelExecApprovalProfile,
  isChannelExecApprovalClientEnabledFromConfig,
  isChannelExecApprovalTargetRecipient,
  matchesApprovalRequestFilters,
} from "openclaw/plugin-sdk/approval-client-runtime"
import { resolveApprovalRequestChannelAccountId } from "openclaw/plugin-sdk/approval-native-runtime"
import type {
  ExecApprovalRequest,
  PluginApprovalRequest,
} from "openclaw/plugin-sdk/approval-runtime"
import type { OpenClawConfig } from "openclaw/plugin-sdk/core"
import {
  normalizeLowercaseStringOrEmpty,
  normalizeOptionalString,
} from "openclaw/plugin-sdk/string-coerce-runtime"
import { listInlineAccountIds, resolveInlineAccount } from "./accounts.js"
import { normalizeAccountId } from "../openclaw-compat.js"

type ApprovalRequest = ExecApprovalRequest | PluginApprovalRequest
type InlineExecApprovalConfig = {
  enabled?: boolean | "auto"
  approvers?: Array<string | number>
  agentFilter?: string[]
  sessionFilter?: string[]
  target?: "dm" | "channel" | "both"
}

function normalizeInlineDirectUserId(value: string | number): string | undefined {
  let trimmed = String(value).trim()
  if (!trimmed) {
    return undefined
  }
  trimmed = trimmed.replace(/^inline:/i, "").trim()
  if (/^chat:/i.test(trimmed)) {
    return undefined
  }
  trimmed = trimmed.replace(/^user:/i, "").trim()
  return /^[0-9]+$/.test(trimmed) ? trimmed : undefined
}

function resolveInlineOwnerApprovers(cfg: OpenClawConfig): Array<string | number> {
  const ownerAllowFrom = cfg.commands?.ownerAllowFrom
  return Array.isArray(ownerAllowFrom) ? ownerAllowFrom : []
}

export function resolveInlineExecApprovalConfig(params: {
  cfg: OpenClawConfig
  accountId?: string | null
}): InlineExecApprovalConfig | undefined {
  const account = resolveInlineAccount(params)
  const config = account.config.execApprovals
  const enabled =
    account.enabled && account.tokenSource !== "none" ? (config?.enabled ?? "auto") : false
  return {
    enabled,
    ...(config?.approvers ? { approvers: config.approvers } : {}),
    ...(config?.agentFilter ? { agentFilter: config.agentFilter } : {}),
    ...(config?.sessionFilter ? { sessionFilter: config.sessionFilter } : {}),
    ...(config?.target ? { target: config.target } : {}),
  }
}

export function getInlineExecApprovalApprovers(params: {
  cfg: OpenClawConfig
  accountId?: string | null
}): string[] {
  const explicit = resolveInlineExecApprovalConfig(params)?.approvers
  return resolveApprovalApprovers({
    ...(explicit ? { explicit } : {}),
    allowFrom: resolveInlineOwnerApprovers(params.cfg),
    normalizeApprover: normalizeInlineDirectUserId,
  })
}

export function isInlineExecApprovalTargetRecipient(params: {
  cfg: OpenClawConfig
  senderId?: string | null
  accountId?: string | null
}): boolean {
  return isChannelExecApprovalTargetRecipient({
    ...params,
    channel: "inline",
    normalizeSenderId: normalizeInlineDirectUserId,
    matchTarget: ({ target, normalizedSenderId }) =>
      normalizeInlineDirectUserId(target.to) === normalizedSenderId,
  })
}

function countInlineExecApprovalEligibleAccounts(params: {
  cfg: OpenClawConfig
  request: ApprovalRequest
}): number {
  return listInlineAccountIds(params.cfg).filter((accountId) => {
    const account = resolveInlineAccount({ cfg: params.cfg, accountId })
    if (!account.enabled || account.tokenSource === "none") {
      return false
    }
    const config = resolveInlineExecApprovalConfig({
      cfg: params.cfg,
      accountId,
    })
    return (
      isChannelExecApprovalClientEnabledFromConfig({
        ...(config?.enabled !== undefined ? { enabled: config.enabled } : {}),
        approverCount: getInlineExecApprovalApprovers({ cfg: params.cfg, accountId }).length,
      }) &&
      matchesApprovalRequestFilters({
        request: params.request.request,
        ...(config?.agentFilter ? { agentFilter: config.agentFilter } : {}),
        ...(config?.sessionFilter ? { sessionFilter: config.sessionFilter } : {}),
        fallbackAgentIdFromSessionKey: true,
      })
    )
  }).length
}

function isExecApprovalRequest(request: ApprovalRequest): request is ExecApprovalRequest {
  return "command" in request.request
}

function isTargetForwardingMode(mode?: string): boolean {
  return mode === "targets" || mode === "both"
}

function matchesExplicitInlineForwardTargetAccount(params: {
  cfg: OpenClawConfig
  accountId?: string | null
  request: ApprovalRequest
}): boolean | undefined {
  const forwardingConfig = isExecApprovalRequest(params.request)
    ? params.cfg.approvals?.exec
    : params.cfg.approvals?.plugin
  if (!forwardingConfig?.enabled || !isTargetForwardingMode(forwardingConfig.mode)) {
    return undefined
  }
  const inlineTargets = (forwardingConfig.targets ?? []).filter(
    (target) => normalizeLowercaseStringOrEmpty(target.channel) === "inline",
  )
  if (inlineTargets.some((target) => !normalizeOptionalString(target.accountId))) {
    return undefined
  }
  const scopedInlineAccountIds = inlineTargets
    .map((target) => normalizeOptionalString(target.accountId))
    .filter((accountId): accountId is string => Boolean(accountId))
  if (scopedInlineAccountIds.length === 0) {
    return undefined
  }
  const accountId = params.accountId ? normalizeAccountId(params.accountId) : ""
  return (
    Boolean(accountId) &&
    scopedInlineAccountIds.some((candidate) => normalizeAccountId(candidate) === accountId)
  )
}

function matchesInlineRequestAccount(params: {
  cfg: OpenClawConfig
  accountId?: string | null
  request: ApprovalRequest
}): boolean {
  const explicitTargetMatch = matchesExplicitInlineForwardTargetAccount(params)
  if (explicitTargetMatch !== undefined) {
    return explicitTargetMatch
  }
  const turnSourceChannel = normalizeLowercaseStringOrEmpty(
    params.request.request.turnSourceChannel,
  )
  const boundAccountId = resolveApprovalRequestChannelAccountId({
    cfg: params.cfg,
    request: params.request,
    channel: "inline",
  })
  if (turnSourceChannel && turnSourceChannel !== "inline" && !boundAccountId) {
    return (
      countInlineExecApprovalEligibleAccounts({
        cfg: params.cfg,
        request: params.request,
      }) <= 1
    )
  }
  return (
    !boundAccountId ||
    !params.accountId ||
    normalizeAccountId(boundAccountId) === normalizeAccountId(params.accountId)
  )
}

const inlineExecApprovalProfile = createChannelExecApprovalProfile({
  resolveConfig: resolveInlineExecApprovalConfig,
  resolveApprovers: getInlineExecApprovalApprovers,
  normalizeSenderId: normalizeInlineDirectUserId,
  isTargetRecipient: isInlineExecApprovalTargetRecipient,
  matchesRequestAccount: matchesInlineRequestAccount,
  fallbackAgentIdFromSessionKey: true,
  requireClientEnabledForLocalPromptSuppression: false,
})

export const isInlineExecApprovalClientEnabled = inlineExecApprovalProfile.isClientEnabled
export const isInlineExecApprovalApprover = inlineExecApprovalProfile.isApprover
export const isInlineExecApprovalAuthorizedSender =
  inlineExecApprovalProfile.isAuthorizedSender
export const resolveInlineExecApprovalTarget = inlineExecApprovalProfile.resolveTarget
export const shouldHandleInlineExecApprovalRequest =
  inlineExecApprovalProfile.shouldHandleRequest

export function isInlineExecApprovalHandlerConfigured(params: {
  cfg: OpenClawConfig
  accountId?: string | null
}): boolean {
  const config = resolveInlineExecApprovalConfig(params)
  return isChannelExecApprovalClientEnabledFromConfig({
    ...(config?.enabled !== undefined ? { enabled: config.enabled } : {}),
    approverCount: getInlineExecApprovalApprovers(params).length,
  })
}
