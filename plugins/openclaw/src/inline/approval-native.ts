import {
  createApproverRestrictedNativeApprovalCapabilityAsync,
  splitChannelApprovalCapability,
} from "openclaw/plugin-sdk/approval-delivery-runtime"
import { createLazyChannelApprovalNativeRuntimeAdapterAsync } from "openclaw/plugin-sdk/approval-handler-adapter-runtime"
import {
  createChannelApproverDmTargetResolverAsync,
  createChannelNativeOriginTargetResolverAsync,
  resolveApprovalRequestSessionConversation,
  type ApprovalRequestSessionDelivery,
} from "openclaw/plugin-sdk/approval-native-runtime"
import {
  buildExecApprovalPendingReplyPayload,
  resolveExecApprovalCommandDisplay,
  resolveExecApprovalRequestAllowedDecisions,
} from "openclaw/plugin-sdk/approval-reply-runtime"
import type {
  ExecApprovalRequest,
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
import { INLINE_APPROVAL_EVENT_KINDS, type InlineApprovalRequest as ApprovalRequest } from "./approval-contract.js"
import {
  getInlineExecApprovalApprovers,
  isInlineExecApprovalApprover,
  isInlineExecApprovalAuthorizedSender,
  isInlineExecApprovalClientEnabled,
  isInlineExecApprovalTargetRecipient,
  resolveInlineExecApprovalTarget,
  shouldHandleInlineExecApprovalRequest,
} from "./exec-approvals.js"

type InlineOriginTarget = { to: string; threadId?: string }
type InlineApprovalNativeRuntimeAdapter = NonNullable<ChannelApprovalCapability["nativeRuntimeAsync"]>

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
  sessionDelivery?: ApprovalRequestSessionDelivery | null | undefined
}): {
  cfg: OpenClawConfig
  accountId?: string | null
  request: ApprovalRequest
  sessionDelivery?: ApprovalRequestSessionDelivery | null
} {
  return {
    ...accountParams(params),
    request: params.request,
    ...(params.sessionDelivery !== undefined ? { sessionDelivery: params.sessionDelivery } : {}),
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

const resolveInlineOriginTarget = createChannelNativeOriginTargetResolverAsync({
  channel: "inline",
  shouldHandleRequest: ({ cfg, accountId, request, sessionDelivery }) =>
    shouldHandleInlineExecApprovalRequest(requestParams({ cfg, accountId, request, sessionDelivery })),
  resolveTurnSourceTarget: resolveTurnSourceInlineOriginTarget,
  resolveSessionTarget: resolveSessionInlineOriginTarget,
  normalizeTargetForMatch: normalizeInlineOriginTarget,
  targetsMatch: inlineTargetsMatch,
  resolveFallbackTarget: resolveInlineFallbackOriginTarget,
})

const resolveInlineApproverUserDmTargets = createChannelApproverDmTargetResolverAsync({
  shouldHandleRequest: ({ cfg, accountId, request, sessionDelivery }) =>
    shouldHandleInlineExecApprovalRequest(requestParams({ cfg, accountId, request, sessionDelivery })),
  resolveApprovers: getInlineExecApprovalApprovers,
  mapApprover: (approver) => ({ to: `user:${approver}` }),
})

type InlineApproverDmTargetsInput = Parameters<typeof resolveInlineApproverUserDmTargets>[0]

async function resolveInlineDmPeerUserId(params: {
  cfg: OpenClawConfig
  accountId?: string | null
  chatId: bigint
}): Promise<string | null> {
  const { withInlineFollowClient } = await import("./follow-command.js")
  return await withInlineFollowClient({
    cfg: params.cfg,
    accountId: params.accountId ?? null,
    fn: async (client) => {
      const chat = await client.getChat({ chatId: params.chatId })
      const peer = chat.peer?.type
      return peer?.oneofKind === "user" ? String(peer.user.userId) : null
    },
  })
}

// An approval asked in the approver's own DM goes back to that DM. Name it by
// the origin's chat target so the host sees the prompt reached the origin and
// doesn't also post "I sent the approval request to Inline DMs, not this chat".
async function resolveInlineApproverDmTargets(input: InlineApproverDmTargetsInput) {
  const targets = await resolveInlineApproverUserDmTargets(input)
  const origin = resolveTurnSourceInlineOriginTarget(input.request as ApprovalRequest)
  const chatId = origin && !origin.threadId ? origin.to.match(/^chat:([0-9]+)$/)?.[1] : undefined
  if (!chatId || targets.length === 0) return targets
  const peerUserId = await resolveInlineDmPeerUserId({
    cfg: input.cfg,
    accountId: input.accountId ?? null,
    chatId: BigInt(chatId),
  }).catch(() => null)
  if (!peerUserId) return targets
  return targets.map((target) =>
    target.to === `user:${peerUserId}` ? { ...target, to: `chat:${chatId}` } : target)
}

function describeInlineExecApprovalSetup(params: { accountId?: string | null }): string {
  const prefix =
    params.accountId && params.accountId !== "default"
      ? `channels.inline.accounts.${params.accountId}`
      : "channels.inline"
  return `Approve it from the Web UI or terminal UI for now. Inline supports native exec approvals for this account. Configure \`${prefix}.execApprovals.approvers\` or \`commands.ownerAllowFrom\`; leave \`${prefix}.execApprovals.enabled\` unset/\`auto\` or set it to \`true\`.`
}

const inlineNativeApprovalCapability = createApproverRestrictedNativeApprovalCapabilityAsync({
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
  isNativeDeliveryEnabled: async ({ cfg, accountId }) =>
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
  nativeRuntimeAsync: createLazyChannelApprovalNativeRuntimeAdapterAsync({
    eventKinds: INLINE_APPROVAL_EVENT_KINDS,
    isConfigured: ({ cfg, accountId }) =>
      isInlineExecApprovalClientEnabled(accountParams({ cfg, accountId })),
    shouldHandle: ({ cfg, accountId, request }) =>
      shouldHandleInlineExecApprovalRequest(requestParams({ cfg, accountId, request })),
    load: async () =>
      loadBundledEntryExportSync<InlineApprovalNativeRuntimeAdapter>(import.meta.url, {
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
