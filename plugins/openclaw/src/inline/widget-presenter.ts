import type { OpenClawConfig } from "openclaw/plugin-sdk/core"
import type { OpenClawPluginApi } from "openclaw/plugin-sdk/channel-entry-contract"
import { InlineSdkClient } from "@inline-chat/realtime-sdk"
import { resolveInlineAccount, resolveInlineToken } from "./accounts.js"
import { getInlineActiveThreadRoute } from "./active-thread-route.js"
import { parseCurrentInlineSession, parseInlineTarget } from "./tool-targets.js"
import {
  buildInlineWidgetHtmlFromOpenClaw,
  buildInlineWidgetMarkdown,
  INLINE_WIDGET_MAX_HTML_BYTES,
  InlineWidgetError,
} from "./widgets.js"

type RegisterWidgetPresenter = NonNullable<OpenClawPluginApi["registerWidgetPresenter"]>
export type InlineWidgetPresenter = Parameters<RegisterWidgetPresenter>[0]
type WidgetPresenterContext = Parameters<NonNullable<InlineWidgetPresenter["match"]>>[0]
type WidgetPresentResult = Awaited<ReturnType<InlineWidgetPresenter["present"]>>
type WidgetMessageReceipt = Extract<
  Extract<WidgetPresentResult, { ok: true }>["value"],
  { kind: "message" }
>["receipt"]

type InlineWidgetDestination = {
  accountId: string | null
  send: { chatId: bigint } | { userId: bigint }
  threadId?: string
}

type InlineWidgetSendClient = Pick<InlineSdkClient, "connect" | "close" | "sendMessage">

export type InlineWidgetPresenterDeps = {
  readConfig: () => OpenClawConfig | undefined
  createClient?: (params: { baseUrl: string; token: string }) => InlineWidgetSendClient
  now?: () => number
}

function isInlineChannel(value: string | undefined): boolean {
  const normalized = value?.trim().toLowerCase()
  return normalized === "inline" || normalized === "inline-chat"
}

function normalizeThreadChatId(threadId: string | number | undefined): string | undefined {
  if (threadId == null) return undefined
  const text = String(threadId).trim()
  return /^[0-9]+$/.test(text) ? text : undefined
}

/** The current Inline chat from trusted delivery facts, or null outside Inline. */
export function resolveInlineWidgetDestination(context: WidgetPresenterContext): InlineWidgetDestination | null {
  const delivery = context.deliveryContext
  const channelIsInline = isInlineChannel(context.messageChannel) ||
    (context.messageChannel == null && isInlineChannel(delivery?.channel))
  if (!channelIsInline) return null
  if (delivery?.channel != null && !isInlineChannel(delivery.channel)) return null
  const accountId = context.accountId ?? delivery?.accountId ?? null

  const rawTarget = delivery?.to ?? context.currentMessagingTarget ?? context.currentChannelId
  if (rawTarget?.trim()) {
    try {
      const target = parseInlineTarget(rawTarget, "widget target")
      const threadId = normalizeThreadChatId(delivery?.threadId)
      if (target.peerId.type.oneofKind === "user") {
        return { accountId, send: { userId: target.peerId.type.user.userId } }
      }
      // Inline reply threads are chats; the thread id is the child chat.
      const chatId = threadId ? BigInt(threadId) : target.peerId.type.chat.chatId
      return { accountId, send: { chatId }, ...(threadId ? { threadId } : {}) }
    } catch {
      // Fall back to the session route below.
    }
  }

  try {
    if (!context.sessionKey) return null
    const session = parseCurrentInlineSession({ messageChannel: "inline", sessionKey: context.sessionKey })
    if (!session) return null
    const type = session.target.peerId.type
    return type.oneofKind === "user"
      ? { accountId, send: { userId: type.user.userId } }
      : {
          accountId,
          send: { chatId: type.chat.chatId },
          ...(session.threadId != null ? { threadId: String(session.threadId) } : {}),
        }
  } catch {
    return null
  }
}

function presentationError(message: string) {
  return { ok: false as const, error: { code: "presentation_error" as const, message } }
}

function unavailable(message: string) {
  return { ok: false as const, error: { code: "unavailable" as const, message } }
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

/**
 * Presents OpenClaw `show_widget` HTML as one Inline widget message in the
 * current chat or reply thread.
 */
export function createInlineWidgetPresenter(deps: InlineWidgetPresenterDeps): InlineWidgetPresenter {
  const createClient = deps.createClient ?? ((params) => new InlineSdkClient(params))
  const now = deps.now ?? Date.now

  const resolveAccount = (destination: InlineWidgetDestination) => {
    const cfg = deps.readConfig()
    if (!cfg) return null
    const account = resolveInlineAccount({ cfg, accountId: destination.accountId })
    return account.configured && account.baseUrl ? account : null
  }

  return {
    target: "current_channel",
    description: "Post the widget as an Inline widget message in the current chat",
    capabilities: {
      sourceKinds: ["html"],
      maxSourceBytes: INLINE_WIDGET_MAX_HTML_BYTES,
    },
    match: (context) => resolveInlineWidgetDestination(context) != null,
    availability: async (context) => {
      const destination = resolveInlineWidgetDestination(context)
      if (!destination) return unavailable("Inline widgets need a current Inline chat.")
      if (!resolveAccount(destination)) {
        return unavailable("The Inline account for this chat is not configured.")
      }
      return { ok: true, value: { available: true } }
    },
    present: async ({ document, title, context }) => {
      const destination = resolveInlineWidgetDestination(context)
      if (!destination) return unavailable("Inline widgets need a current Inline chat.")
      const account = resolveAccount(destination)
      if (!account?.baseUrl) return unavailable("The Inline account for this chat is not configured.")

      let text: string
      try {
        text = buildInlineWidgetMarkdown({ html: buildInlineWidgetHtmlFromOpenClaw(document.html), title })
      } catch (error) {
        if (error instanceof InlineWidgetError) return presentationError(error.message)
        throw error
      }

      const route = getInlineActiveThreadRoute({ accountId: account.accountId, sessionKey: context.sessionKey })
      const widgetChatId = "chatId" in destination.send ? destination.send.chatId
        : route?.parentPeer.kind === "direct" && route.threadId == null && route.parentPeer.id === String(destination.send.userId)
          ? route.sourceChatId : undefined
      let client: InlineWidgetSendClient | null = null
      try {
        const token = await resolveInlineToken(account)
        client = createClient({ baseUrl: account.baseUrl, token })
        await client.connect()
        // One message: the server turns the block into a widget and keeps its title as text.
        const sent = await client.sendMessage({ ...destination.send, text, parseMarkdown: true })
        const messageId = sent.messageId != null ? String(sent.messageId) : undefined
        if (messageId && route && widgetChatId === (route.threadId ?? route.sourceChatId)) {
          route.deliveredWidgetChatId = widgetChatId
        }
        const receipt: WidgetMessageReceipt = {
          ...(messageId ? { primaryPlatformMessageId: messageId } : {}),
          platformMessageIds: messageId ? [messageId] : [],
          parts: messageId
            ? [{
                platformMessageId: messageId,
                kind: "card",
                index: 0,
                ...(destination.threadId ? { threadId: destination.threadId } : {}),
              }]
            : [],
          ...(destination.threadId ? { threadId: destination.threadId } : {}),
          sentAt: now(),
        }
        return { ok: true, value: { kind: "message", receipt } }
      } catch (error) {
        return presentationError(`Inline rejected the widget: ${errorMessage(error)}`)
      } finally {
        await client?.close().catch(() => {})
      }
    },
  }
}

/** Registers the presenter on hosts that support widget presenters; older hosts skip it. */
export function registerInlineWidgetPresenter(api: OpenClawPluginApi): boolean {
  const host = api as { registerWidgetPresenter?: RegisterWidgetPresenter }
  if (typeof host.registerWidgetPresenter !== "function") return false
  const runtimeConfig = (api as { runtime?: { config?: { current?: () => unknown } } }).runtime?.config
  host.registerWidgetPresenter(createInlineWidgetPresenter({
    readConfig: () => {
      const current = typeof runtimeConfig?.current === "function" ? runtimeConfig.current() : undefined
      return (current ?? api.config) as OpenClawConfig | undefined
    },
  }))
  return true
}
