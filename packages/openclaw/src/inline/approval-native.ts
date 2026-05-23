import {
  createApproverRestrictedNativeApprovalCapability,
  splitChannelApprovalCapability,
} from "openclaw/plugin-sdk/approval-delivery-runtime"
import { createLazyChannelApprovalNativeRuntimeAdapter } from "openclaw/plugin-sdk/approval-handler-adapter-runtime"
import type { ChannelApprovalNativeRuntimeAdapter } from "openclaw/plugin-sdk/approval-handler-runtime"
import {
  createChannelApproverDmTargetResolver,
  createChannelNativeOriginTargetResolver,
  resolveApprovalRequestSessionConversation,
} from "openclaw/plugin-sdk/approval-native-runtime"
import {
  buildExecApprovalPendingReplyPayload,
  resolveExecApprovalCommandDisplay,
  resolveExecApprovalRequestAllowedDecisions,
} from "openclaw/plugin-sdk/approval-reply-runtime"
import type {
  ExecApprovalRequest,
  PluginApprovalRequest,
} from "openclaw/plugin-sdk/approval-runtime"
import type { ChannelApprovalCapability } from "openclaw/plugin-sdk/channel-contract"
import { loadBundledEntryExportSync } from "openclaw/plugin-sdk/channel-entry-contract"
import type { OpenClawConfig } from "openclaw/plugin-sdk/core"
import type { ReplyPayload } from "openclaw/plugin-sdk/reply-runtime"
import {
  normalizeLowercaseStringOrEmpty,
  normalizeOptionalString,
} from "openclaw/plugin-sdk/string-coerce-runtime"
import { listInlineAccountIds } from "./accounts.js"
import {
  getInlineExecApprovalApprovers,
  isInlineExecApprovalApprover,
  isInlineExecApprovalAuthorizedSender,
  isInlineExecApprovalClientEnabled,
  isInlineExecApprovalTargetRecipient,
  resolveInlineExecApprovalTarget,
  shouldHandleInlineExecApprovalRequest,
} from "./exec-approvals.js"

type ApprovalRequest = ExecApprovalRequest | PluginApprovalRequest
type InlineOriginTarget = { to: string; threadId?: string }

function accountParams(params: {
  cfg: OpenClawConfig
  accountId?: string | null | undefined
}): { cfg: OpenClawConfig; accountId?: string | null } {
  return {
    cfg: params.cfg,
    ...(params.accountId !== undefined ? { accountId: params.accountId } : {}),
  }
}

function senderParams(params: {
  cfg: OpenClawConfig
  accountId?: string | null | undefined
  senderId?: string | null | undefined
}): { cfg: OpenClawConfig; accountId?: string | null; senderId?: string | null } {
  return {
    ...accountParams(params),
    ...(params.senderId !== undefined ? { senderId: params.senderId } : {}),
  }
}

function requestParams(params: {
  cfg: OpenClawConfig
  accountId?: string | null | undefined
  request: ApprovalRequest
}): { cfg: OpenClawConfig; accountId?: string | null; request: ApprovalRequest } {
  return {
    ...accountParams(params),
    request: params.request,
  }
}

function normalizeThreadId(value?: string | number | null): string | undefined {
  if (typeof value === "number") {
    return Number.isFinite(value) ? String(value) : undefined
  }
  const trimmed = normalizeOptionalString(value)
  return trimmed || undefined
}

function normalizeInlineOriginTargetTo(value: string, defaultKind: "chat" | "user" = "chat"): string | null {
  let target = value.trim().replace(/^inline:/i, "").trim()
  if (!target) {
    return null
  }

  let kind = defaultKind
  if (/^chat:/i.test(target)) {
    kind = "chat"
    target = target.replace(/^chat:/i, "").trim()
  } else if (/^user:/i.test(target)) {
    kind = "user"
    target = target.replace(/^user:/i, "").trim()
  }

  if (!/^[0-9]+$/.test(target)) {
    return null
  }
  return `${kind}:${target}`
}

function normalizeInlineOriginTarget(
  target: InlineOriginTarget,
): InlineOriginTarget | null {
  const to = normalizeInlineOriginTargetTo(target.to)
  if (!to) {
    return null
  }
  const threadId = to.startsWith("user:") ? undefined : normalizeThreadId(target.threadId)
  return {
    to,
    ...(threadId ? { threadId } : {}),
  }
}

function inlineTargetsMatch(a: InlineOriginTarget, b: InlineOriginTarget): boolean {
  const left = normalizeInlineOriginTarget(a)
  const right = normalizeInlineOriginTarget(b)
  return Boolean(left && right && left.to === right.to && left.threadId === right.threadId)
}

function resolveTurnSourceInlineOriginTarget(request: ApprovalRequest): InlineOriginTarget | null {
  const turnSourceChannel = normalizeLowercaseStringOrEmpty(request.request.turnSourceChannel)
  const rawTurnSourceTo = normalizeOptionalString(request.request.turnSourceTo) ?? ""
  if (turnSourceChannel !== "inline" || !rawTurnSourceTo) {
    return null
  }
  const to = normalizeInlineOriginTargetTo(rawTurnSourceTo)
  if (!to) {
    return null
  }
  const threadId = to.startsWith("user:")
    ? undefined
    : normalizeThreadId(request.request.turnSourceThreadId)
  return {
    to,
    ...(threadId ? { threadId } : {}),
  }
}

function resolveSessionInlineOriginTarget(sessionTarget: {
  to: string
  threadId?: string | number | null
}): InlineOriginTarget | null {
  const to = normalizeInlineOriginTargetTo(sessionTarget.to)
  if (!to) {
    return null
  }
  const threadId = to.startsWith("user:") ? undefined : normalizeThreadId(sessionTarget.threadId)
  return {
    to,
    ...(threadId ? { threadId } : {}),
  }
}

function resolveInlineFallbackOriginTarget(request: ApprovalRequest): InlineOriginTarget | null {
  const sessionTarget = resolveApprovalRequestSessionConversation({
    request,
    channel: "inline",
    bundledFallback: false,
  })
  if (!sessionTarget) {
    return null
  }
  const to = normalizeInlineOriginTargetTo(sessionTarget.id)
  if (!to || to.startsWith("user:")) {
    return null
  }
  return {
    to,
    ...(sessionTarget.threadId ? { threadId: sessionTarget.threadId } : {}),
  }
}

const resolveInlineOriginTarget = createChannelNativeOriginTargetResolver({
  channel: "inline",
  shouldHandleRequest: ({ cfg, accountId, request }) =>
    shouldHandleInlineExecApprovalRequest(requestParams({ cfg, accountId, request })),
  resolveTurnSourceTarget: resolveTurnSourceInlineOriginTarget,
  resolveSessionTarget: resolveSessionInlineOriginTarget,
  normalizeTargetForMatch: normalizeInlineOriginTarget,
  targetsMatch: inlineTargetsMatch,
  resolveFallbackTarget: resolveInlineFallbackOriginTarget,
})

const resolveInlineApproverDmTargets = createChannelApproverDmTargetResolver({
  shouldHandleRequest: ({ cfg, accountId, request }) =>
    shouldHandleInlineExecApprovalRequest(requestParams({ cfg, accountId, request })),
  resolveApprovers: getInlineExecApprovalApprovers,
  mapApprover: (approver) => ({ to: `user:${approver}` }),
})

function describeInlineExecApprovalSetup(params: { accountId?: string | null }): string {
  const prefix =
    params.accountId && params.accountId !== "default"
      ? `channels.inline.accounts.${params.accountId}`
      : "channels.inline"
  return `Approve it from the Web UI or terminal UI for now. Inline supports native exec approvals for this account. Configure \`${prefix}.execApprovals.approvers\` or \`commands.ownerAllowFrom\`; leave \`${prefix}.execApprovals.enabled\` unset/\`auto\` or set it to \`true\`.`
}

const inlineNativeApprovalCapability = createApproverRestrictedNativeApprovalCapability({
  channel: "inline",
  channelLabel: "Inline",
  describeExecApprovalSetup: describeInlineExecApprovalSetup,
  listAccountIds: listInlineAccountIds,
  hasApprovers: ({ cfg, accountId }) =>
    getInlineExecApprovalApprovers(accountParams({ cfg, accountId })).length > 0,
  isExecAuthorizedSender: ({ cfg, accountId, senderId }) =>
    isInlineExecApprovalAuthorizedSender(senderParams({ cfg, accountId, senderId })),
  isPluginAuthorizedSender: ({ cfg, accountId, senderId }) =>
    isInlineExecApprovalApprover(senderParams({ cfg, accountId, senderId })),
  isNativeDeliveryEnabled: ({ cfg, accountId }) =>
    isInlineExecApprovalClientEnabled(accountParams({ cfg, accountId })),
  resolveNativeDeliveryMode: ({ cfg, accountId }) =>
    resolveInlineExecApprovalTarget(accountParams({ cfg, accountId })),
  requireMatchingTurnSourceChannel: true,
  resolveSuppressionAccountId: ({ target, request }) =>
    normalizeOptionalString(target.accountId) ??
    normalizeOptionalString(request.request.turnSourceAccountId),
  resolveOriginTarget: resolveInlineOriginTarget,
  resolveApproverDmTargets: resolveInlineApproverDmTargets,
  notifyOriginWhenDmOnly: true,
  nativeRuntime: createLazyChannelApprovalNativeRuntimeAdapter({
    eventKinds: ["exec", "plugin"],
    isConfigured: ({ cfg, accountId }) =>
      isInlineExecApprovalClientEnabled(accountParams({ cfg, accountId })),
    shouldHandle: ({ cfg, accountId, request }) =>
      shouldHandleInlineExecApprovalRequest(requestParams({ cfg, accountId, request })),
    load: async () =>
      loadBundledEntryExportSync<ChannelApprovalNativeRuntimeAdapter>(import.meta.url, {
        specifier: "./approval-handler.runtime.js",
        exportName: "inlineApprovalNativeRuntime",
      }),
  }),
})

const resolveInlineApproveCommandBehavior: NonNullable<
  ChannelApprovalCapability["resolveApproveCommandBehavior"]
> = (
  params: Parameters<NonNullable<ChannelApprovalCapability["resolveApproveCommandBehavior"]>>[0],
) => {
  const { cfg, accountId, senderId, approvalKind } = params
  if (approvalKind !== "exec") {
    return undefined
  }
  if (isInlineExecApprovalClientEnabled(accountParams({ cfg, accountId }))) {
    return undefined
  }
  if (isInlineExecApprovalTargetRecipient(senderParams({ cfg, accountId, senderId }))) {
    return undefined
  }
  const actor = senderParams({ cfg, accountId, senderId })
  if (
    isInlineExecApprovalAuthorizedSender(actor) &&
    !isInlineExecApprovalApprover(actor)
  ) {
    return undefined
  }
  return {
    kind: "reply",
    text: "\u274c Inline exec approvals are not enabled for this bot account.",
  }
}

export function buildInlineExecApprovalPendingPayload(params: {
  request: ExecApprovalRequest
  nowMs: number
}): ReplyPayload {
  const request = params.request.request
  return buildExecApprovalPendingReplyPayload({
    approvalId: params.request.id,
    approvalSlug: params.request.id.slice(0, 8),
    approvalCommandId: params.request.id,
    ...(request.warningText ? { warningText: request.warningText } : {}),
    command: resolveExecApprovalCommandDisplay(request).commandText,
    ...(request.cwd ? { cwd: request.cwd } : {}),
    host: request.host === "node" ? "node" : "gateway",
    ...(request.nodeId ? { nodeId: request.nodeId } : {}),
    ...(request.agentId ? { agentId: request.agentId } : {}),
    ...(request.sessionKey ? { sessionKey: request.sessionKey } : {}),
    allowedDecisions: resolveExecApprovalRequestAllowedDecisions(request),
    expiresAtMs: params.request.expiresAtMs,
    nowMs: params.nowMs,
  })
}

export const inlineApprovalCapability: ChannelApprovalCapability = {
  ...inlineNativeApprovalCapability,
  resolveApproveCommandBehavior: resolveInlineApproveCommandBehavior,
}

export const inlineNativeApprovalAdapter = splitChannelApprovalCapability(
  inlineApprovalCapability,
)
