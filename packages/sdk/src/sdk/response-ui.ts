import type { MessageActionResponseUi } from "@inline-chat/protocol/core"

export type InlineOpenUrlOptions = {
  /**
   * The URL carries a credential, such as a one-time login. Inline keeps it out
   * of logs and synced history, and apps never show or copy it.
   */
  sensitive?: boolean
  /** The machine the URL belongs to, for messages ("Mo's MacBook Pro"). */
  hostLabel?: string
  /**
   * Shown instead of opening when a loopback URL can't be reached from the
   * device the person pressed on, for example how to make it reachable.
   */
  unreachableText?: string
}

/**
 * What a bot shows or does for the person who pressed one of its controls: a
 * message action button, a work bar control or an Agent Settings item. Pass
 * the result as `ui` to `answerMessageAction`, or on a `BotChatSettingsResponse`
 * answering an item invocation.
 */
export const InlineResponseUi = {
  toast(text: string): MessageActionResponseUi {
    return { kind: { oneofKind: "toast", toast: { text } } }
  },

  alert(text: string, title?: string): MessageActionResponseUi {
    return { kind: { oneofKind: "alert", alert: { text, ...(title ? { title } : {}) } } }
  },

  /** Opens `url` on the pressing device, within 30 seconds of the press. */
  openUrl(url: string, options: InlineOpenUrlOptions = {}): MessageActionResponseUi {
    return {
      kind: {
        oneofKind: "openUrl",
        openUrl: {
          url,
          sensitive: options.sensitive ?? false,
          ...(options.hostLabel ? { hostLabel: options.hostLabel } : {}),
          ...(options.unreachableText ? { unreachableText: options.unreachableText } : {}),
        },
      },
    }
  },
} as const
