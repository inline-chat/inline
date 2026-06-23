import type {
  ChannelApprovalCapabilityHandlerContext,
  PendingApprovalView,
} from "openclaw/plugin-sdk/approval-handler-runtime"
import { createChannelApprovalNativeRuntimeAdapter } from "openclaw/plugin-sdk/approval-handler-runtime"
import { buildChannelApprovalNativeTargetKey } from "openclaw/plugin-sdk/approval-native-runtime"
import {
  buildExecApprovalPendingReplyPayload,
  buildPluginApprovalPendingReplyPayload,
} from "openclaw/plugin-sdk/approval-reply-runtime"
import type {
  ExecApprovalRequest,
  PluginApprovalRequest,
} from "openclaw/plugin-sdk/approval-runtime"
import { createSubsystemLogger } from "openclaw/plugin-sdk/runtime-env"
import { normalizeOptionalString } from "openclaw/plugin-sdk/string-coerce-runtime"
import {
  BotPresenceState_Kind,
  InlineSdkClient,
  Method,
  type InputPeer,
  type MessageActions,
} from "@inline-chat/realtime-sdk"
import { resolveInlineMessageActionsParam } from "./actions.js"
import {
  isInlineExecApprovalHandlerConfigured,
  shouldHandleInlineExecApprovalRequest,
} from "./exec-approvals.js"
import { sanitizeInlineOutgoingText } from "./message-formatting.js"
import { resolveInlineReplyThreadChatId } from "./reply-threads.js"

const log = createSubsystemLogger("inline/approvals")

type ApprovalRequest = ExecApprovalRequest | PluginApprovalRequest
type InlinePendingDelivery = {
  text: string
  actions?: MessageActions
}
type InlineApprovalSendTarget = { chatId: bigint } | { userId: bigint }
type InlinePreparedTarget = {
  sendTarget: InlineApprovalSendTarget
  peerId: InputPeer
  typingChatId?: bigint
}
type InlinePendingApproval = {
  messageId: bigint
  peerId: InputPeer
  text: string
  parseMarkdown: boolean
  typingChatId?: bigint
}
type InlineParsedApprovalTarget = {
  kind: "chat" | "user"
  id: bigint
  normalized: string
}

export type InlineApprovalHandlerContext = {
  client: InlineSdkClient
  parseMarkdown?: boolean
}

function resolveHandlerContext(params: ChannelApprovalCapabilityHandlerContext): {
  accountId: string
  context: InlineApprovalHandlerContext
} | null {
  const context = params.context as InlineApprovalHandlerContext | undefined
  const accountId = normalizeOptionalString(params.accountId) ?? ""
  if (!context?.client || !accountId) {
    return null
  }
  return { accountId, context }
}

function handlerContext(params: {
  cfg: ChannelApprovalCapabilityHandlerContext["cfg"]
  accountId?: string | null | undefined
  context?: unknown
}): ChannelApprovalCapabilityHandlerContext {
  return {
    cfg: params.cfg,
    ...(params.accountId !== undefined ? { accountId: params.accountId } : {}),
    ...(params.context !== undefined ? { context: params.context } : {}),
  }
}

function parseInlineApprovalTarget(raw: string): InlineParsedApprovalTarget | null {
  let target = raw.trim().replace(/^inline:/i, "").trim()
  if (!target) {
    return null
  }

  let kind: "chat" | "user" = "chat"
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
  return {
    kind,
    id: BigInt(target),
    normalized: target,
  }
}

function normalizeThreadId(value?: string | number | null): string | undefined {
  if (typeof value === "number") {
    return Number.isFinite(value) ? String(value) : undefined
  }
  const trimmed = normalizeOptionalString(value)
  return trimmed || undefined
}

function buildChatPeer(chatId: bigint): InputPeer {
  return {
    type: {
      oneofKind: "chat",
      chat: { chatId },
    },
  }
}

function buildUserPeer(userId: bigint): InputPeer {
  return {
    type: {
      oneofKind: "user",
      user: { userId },
    },
  }
}

async function sendInlineBotPresenceState(
  client: Partial<Pick<InlineSdkClient, "invokeRaw">>,
  chatId: bigint,
  kind: BotPresenceState_Kind,
): Promise<void> {
  const invokeRaw = client.invokeRaw
  if (typeof invokeRaw !== "function") return
  await invokeRaw.call(client, Method.SET_BOT_PRESENCE_STATE, {
    oneofKind: "setBotPresenceState",
    setBotPresenceState: {
      peerId: {
        type: {
          oneofKind: "chat",
          chat: { chatId },
        },
      },
      state: { kind },
    },
  }).catch(() => {})
}

function buildInlineApprovalActions(view: PendingApprovalView): MessageActions | undefined {
  const buttons = [
    view.actions.map((action) => ({
      text: action.label,
      callback_data: action.command,
    })),
  ]
  return resolveInlineMessageActionsParam({ buttons })
}

function buildPendingPayload(params: {
  request: ApprovalRequest
  approvalKind: "exec" | "plugin"
  nowMs: number
  view: PendingApprovalView
}): InlinePendingDelivery {
  const execView = params.view.approvalKind === "exec" ? params.view : null
  const payload =
    params.approvalKind === "plugin"
      ? buildPluginApprovalPendingReplyPayload({
          request: params.request as PluginApprovalRequest,
          nowMs: params.nowMs,
          allowedDecisions: params.view.actions.map((action) => action.decision),
        })
      : buildExecApprovalPendingReplyPayload({
          approvalId: params.request.id,
          approvalSlug: params.request.id.slice(0, 8),
          approvalCommandId: params.request.id,
          ...(execView?.warningText ? { warningText: execView.warningText } : {}),
          command: execView?.commandText ?? "",
          ...(execView?.cwd ? { cwd: execView.cwd } : {}),
          host: execView?.host === "node" ? "node" : "gateway",
          ...(execView?.nodeId ? { nodeId: execView.nodeId } : {}),
          ...(execView?.agentId ? { agentId: execView.agentId } : {}),
          ...(execView?.sessionKey ? { sessionKey: execView.sessionKey } : {}),
          allowedDecisions: params.view.actions.map((action) => action.decision),
          expiresAtMs: params.request.expiresAtMs,
          nowMs: params.nowMs,
        })

  const text = sanitizeInlineOutgoingText(payload.text ?? "")
  const actions = buildInlineApprovalActions(params.view)
  return {
    text,
    ...(actions ? { actions } : {}),
  }
}

export const inlineApprovalNativeRuntime = createChannelApprovalNativeRuntimeAdapter<
  InlinePendingDelivery,
  InlinePreparedTarget,
  InlinePendingApproval,
  never
>({
  eventKinds: ["exec", "plugin"],
  availability: {
    isConfigured: (params) => {
      const resolved = resolveHandlerContext(params)
      return resolved
        ? isInlineExecApprovalHandlerConfigured({
            cfg: params.cfg,
            accountId: resolved.accountId,
          })
        : false
    },
    shouldHandle: (params) => {
      const resolved = resolveHandlerContext(params)
      return resolved
        ? shouldHandleInlineExecApprovalRequest({
            cfg: params.cfg,
            accountId: resolved.accountId,
            request: params.request,
          })
        : false
    },
  },
  presentation: {
    buildPendingPayload: ({ request, approvalKind, nowMs, view }) =>
      buildPendingPayload({ request, approvalKind, nowMs, view }),
    buildResolvedResult: () => ({ kind: "clear-actions" }),
    buildExpiredResult: () => ({ kind: "clear-actions" }),
  },
  transport: {
    prepareTarget: ({ cfg, accountId, plannedTarget }) => {
      const parsed = parseInlineApprovalTarget(plannedTarget.target.to)
      if (!parsed) {
        return null
      }
      if (parsed.kind === "user") {
        return {
          dedupeKey: buildChannelApprovalNativeTargetKey({ to: `user:${parsed.normalized}` }),
          target: {
            sendTarget: { userId: parsed.id },
            peerId: buildUserPeer(parsed.id),
          },
        }
      }

      const threadId = normalizeThreadId(plannedTarget.target.threadId)
      const chatId = resolveInlineReplyThreadChatId({
        cfg,
        accountId: accountId ?? null,
        parentChatId: parsed.id,
        threadId: threadId ?? null,
      })
      if (chatId == null) {
        return null
      }
      return {
        dedupeKey: buildChannelApprovalNativeTargetKey({
          to: `chat:${parsed.normalized}`,
          ...(threadId ? { threadId } : {}),
        }),
        target: {
          sendTarget: { chatId },
          peerId: buildChatPeer(chatId),
          typingChatId: chatId,
        },
      }
    },
    deliverPending: async ({ cfg, accountId, context, preparedTarget, pendingPayload }) => {
      const resolved = resolveHandlerContext(handlerContext({ cfg, accountId, context }))
      if (!resolved) {
        return null
      }
      let delivered = false
      if (preparedTarget.typingChatId != null) {
        await Promise.all([
          resolved.context.client
            .sendTyping({ chatId: preparedTarget.typingChatId, typing: true })
            .catch(() => {}),
          sendInlineBotPresenceState(
            resolved.context.client,
            preparedTarget.typingChatId,
            BotPresenceState_Kind.WAITING,
          ),
        ])
      }
      try {
        const result = await resolved.context.client.sendMessage({
          ...preparedTarget.sendTarget,
          text: pendingPayload.text,
          ...(pendingPayload.actions ? { actions: pendingPayload.actions } : {}),
          parseMarkdown: resolved.context.parseMarkdown ?? true,
        })
        if (result.messageId == null) {
          return null
        }
        delivered = true
        return {
          messageId: result.messageId,
          peerId: preparedTarget.peerId,
          text: pendingPayload.text,
          parseMarkdown: resolved.context.parseMarkdown ?? true,
          ...(preparedTarget.typingChatId != null ? { typingChatId: preparedTarget.typingChatId } : {}),
        }
      } finally {
        if (preparedTarget.typingChatId != null) {
          await resolved.context.client
            .sendTyping({ chatId: preparedTarget.typingChatId, typing: false })
            .catch(() => {})
          if (!delivered) {
            await sendInlineBotPresenceState(
              resolved.context.client,
              preparedTarget.typingChatId,
              BotPresenceState_Kind.IDLE,
            )
          }
        }
      }
    },
  },
  interactions: {
    clearPendingActions: async ({ cfg, accountId, context, entry }) => {
      const resolved = resolveHandlerContext(handlerContext({ cfg, accountId, context }))
      if (!resolved) {
        return
      }
      await resolved.context.client.invokeRaw(Method.EDIT_MESSAGE, {
        oneofKind: "editMessage",
        editMessage: {
          messageId: entry.messageId,
          peerId: entry.peerId,
          text: entry.text,
          actions: { rows: [] },
          parseMarkdown: entry.parseMarkdown,
        },
      })
      if (entry.typingChatId != null) {
        await sendInlineBotPresenceState(
          resolved.context.client,
          entry.typingChatId,
          BotPresenceState_Kind.IDLE,
        )
      }
    },
  },
  observe: {
    onDeliveryError: ({ error, request }) => {
      log.error(`inline approvals: failed to send request ${request.id}: ${String(error)}`)
    },
  },
})
