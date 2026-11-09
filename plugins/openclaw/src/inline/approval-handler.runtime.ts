import type {
  ChannelApprovalCapabilityHandlerContext,
  ChannelApprovalKind,
  PendingApprovalView,
} from "openclaw/plugin-sdk/approval-handler-runtime"
import { createChannelApprovalNativeRuntimeAdapterAsync } from "openclaw/plugin-sdk/approval-handler-runtime"
import { buildChannelApprovalNativeTargetKey } from "openclaw/plugin-sdk/approval-native-runtime"
import {
  buildExecApprovalPendingReplyPayload,
  buildPluginApprovalPendingReplyPayload,
} from "openclaw/plugin-sdk/approval-reply-runtime"
import type {
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
import { INLINE_APPROVAL_EVENT_KINDS, type InlineApprovalRequest as ApprovalRequest } from "./approval-contract.js"
import {
  isInlineExecApprovalHandlerConfigured,
  shouldHandleInlineExecApprovalRequest,
} from "./exec-approvals.js"
import { sanitizeInlineOutgoingText } from "./message-formatting.js"
import { resolveInlineReplyThreadChatId } from "./reply-threads.js"

const log = createSubsystemLogger("inline/approvals")

type InlinePendingDelivery = {
  text: string
  actions?: MessageActions
  subject?: string
}
type InlineFinalPayload = { text: string }
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
  // What the card asked about, shown again once it is decided or expires.
  subject?: string
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
  return resolveInlineMessageActionsParam({ buttons }, { owner: "system" })
}

function buildPendingPayload(params: {
  request: ApprovalRequest
  approvalKind: ChannelApprovalKind
  nowMs: number
  view: PendingApprovalView
}): InlinePendingDelivery {
  // Structural narrowing keeps this source type-checkable against 2026.8,
  // whose PendingApprovalView union predates system change approvals.
  if (String(params.approvalKind) === "system-agent") {
    const view = params.view
    if (String(view.approvalKind) !== "system-agent" || !("operationSummary" in view)
      || typeof view.operationSummary !== "string") {
      throw new Error("system-agent approval request and view kinds do not match")
    }
    const text = sanitizeInlineOutgoingText([
      "🔒 OpenClaw change requires approval",
      `Change: ${view.operationSummary}`,
      `Agent: ${"agentId" in view ? view.agentId ?? "unknown" : "unknown"}`,
      `Expires in: ${Math.max(0, Math.ceil((params.request.expiresAtMs - params.nowMs) / 1_000))}s`,
    ].join("\n"))
    const actions = buildInlineApprovalActions(view)
    return { text, ...(actions ? { actions } : {}) }
  }
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

  const actions = buildInlineApprovalActions(params.view)
  // OpenClaw's text spells out every /approve command for channels without
  // buttons. With buttons, show what is being approved and let them do the rest.
  const subject = actions ? buildInlineApprovalSubject(params) : null
  const text = sanitizeInlineOutgoingText(subject ? subject.text : payload.text ?? "")
  return {
    text,
    ...(subject ? { subject: subject.summary } : {}),
    ...(actions ? { actions } : {}),
  }
}

function fenced(text: string, language = ""): string {
  const body = text.length > 2000 ? `${text.slice(0, 2000)}…` : text
  const fence = body.includes("```") ? "````" : "```"
  return `${fence}${language}\n${body}\n${fence}`
}

function buildInlineApprovalSubject(params: {
  approvalKind: ChannelApprovalKind
  view: PendingApprovalView
}): { text: string; summary: string } | null {
  const view = params.view as PendingApprovalView & Record<string, unknown>
  const warning = typeof view.warningText === "string" ? view.warningText.trim() : ""
  if (params.approvalKind === "exec") {
    const command = typeof view.commandText === "string" ? view.commandText.trim() : ""
    if (!command) return null
    const summary = fenced(command, "sh")
    return {
      text: [warning, "Command approval required", summary].filter(Boolean).join("\n\n"),
      summary,
    }
  }
  if (params.approvalKind === "plugin") {
    const title = typeof view.title === "string" ? view.title.trim() : ""
    const description = typeof view.description === "string" ? view.description.trim() : ""
    if (!title && !description) return null
    const summary = [title ? `**${title}**` : "", description].filter(Boolean).join("\n")
    return {
      text: [warning, "Approval required", summary].filter(Boolean).join("\n\n"),
      summary,
    }
  }
  return null
}

const INLINE_APPROVAL_DECISION_LABELS: Record<string, string> = {
  "allow-once": "✅ Allowed once",
  "allow-always": "✅ Always allowed",
  deny: "❌ Denied",
}

// Slack, Discord and Telegram all say who answered. A bare id would read as
// noise, so only a name is shown.
function formatInlineApprovalResolver(resolvedBy: unknown): string {
  const value = typeof resolvedBy === "string" ? resolvedBy.trim() : ""
  if (!value || /^(?:inline:)?(?:user:)?\d+$/i.test(value)) return ""
  return `by ${value}`
}

function buildInlineApprovalFinalText(params: {
  entry: InlinePendingApproval
  heading: string
}): string {
  // Cards without a recorded subject (no buttons) keep their own text.
  if (!params.entry.subject) return params.entry.text
  return sanitizeInlineOutgoingText(`${params.heading}\n\n${params.entry.subject}`)
}

// Named through the public factory because the SDK does not export the async adapter type.
type InlineApprovalNativeRuntimeAdapter = ReturnType<
  typeof createChannelApprovalNativeRuntimeAdapterAsync<
    InlinePendingDelivery,
    InlinePreparedTarget,
    InlinePendingApproval,
    never,
    InlineFinalPayload
  >
>

export const inlineApprovalNativeRuntime: InlineApprovalNativeRuntimeAdapter = createChannelApprovalNativeRuntimeAdapterAsync<
  InlinePendingDelivery,
  InlinePreparedTarget,
  InlinePendingApproval,
  never,
  InlineFinalPayload
>({
  eventKinds: INLINE_APPROVAL_EVENT_KINDS,
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
    shouldHandle: async (params) => {
      const resolved = resolveHandlerContext(params)
      return resolved
        ? await shouldHandleInlineExecApprovalRequest({
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
    buildResolvedResult: ({ resolved, view, entry }) => ({
      kind: "update",
      payload: {
        text: buildInlineApprovalFinalText({
          entry,
          heading: [
            INLINE_APPROVAL_DECISION_LABELS[String(resolved.decision)] ?? "Approval resolved",
            formatInlineApprovalResolver(view.resolvedBy ?? resolved.resolvedBy),
          ].filter(Boolean).join(" "),
        }),
      },
    }),
    buildExpiredResult: ({ entry }) => ({
      kind: "update",
      payload: { text: buildInlineApprovalFinalText({ entry, heading: "⌛ Approval expired" }) },
    }),
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
          ...(pendingPayload.subject ? { subject: pendingPayload.subject } : {}),
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
    updateEntry: async ({ cfg, accountId, context, entry, payload }) => {
      const resolved = resolveHandlerContext(handlerContext({ cfg, accountId, context }))
      if (!resolved) {
        return
      }
      await resolved.context.client.invokeRaw(Method.EDIT_MESSAGE, {
        oneofKind: "editMessage",
        editMessage: {
          messageId: entry.messageId,
          peerId: entry.peerId,
          text: payload.text,
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
