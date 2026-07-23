import { useMemo, type ReactNode } from "react"
import * as stylex from "@stylexjs/stylex"
import { InlineContextMenu, type InlineContextMenuItem } from "~/ui/InlineContextMenu"
import type { ChatMessageRow } from "./ChatRowListModel"
import { MessageSendingStatus } from "@inline/client"
import { inlineMessageDeepLink } from "~/inline/navigation/InlineDeepLink"
import { writeInlineClipboardText } from "~/ui/InlineClipboard"
import { useInlineToast } from "~/ui/InlineToast"
import { colors } from "../styles/tokens.stylex"

export function MessageContextMenu({
  children,
  message,
  pinned,
  onReply,
  onTogglePin,
  onResend,
}: {
  children: ReactNode
  message: ChatMessageRow
  pinned: boolean
  onReply: (message: ChatMessageRow) => void
  onTogglePin: (message: ChatMessageRow) => void
  onResend: (messageId: ChatMessageRow["messageId"]) => void
}) {
  const toast = useInlineToast()
  const text = message.presentation.text
  const canReference = BigInt(message.messageId) > 0n
  const items = useMemo<readonly InlineContextMenuItem[]>(
    () => [
      ...(canReference
        ? [
            {
              label: "Reply",
              onSelect: () => onReply(message),
            },
          ]
        : []),
      ...(text
        ? [
            {
              label: "Copy Text",
              onSelect: () => {
                void writeInlineClipboardText(text)
                  .then(() => toast.show("Copied text"))
                  .catch(() => toast.show("Could not copy text", "error"))
              },
            },
          ]
        : []),
      ...(canReference
        ? [
            {
              label: "Copy Link",
              onSelect: () => {
                void writeInlineClipboardText(
                  inlineMessageDeepLink(message.chatId, message.messageId),
                )
                  .then(() => toast.show("Copied link"))
                  .catch(() => toast.show("Could not copy link", "error"))
              },
            },
          ]
        : []),
      ...(message.status === MessageSendingStatus.Failed
        ? [
            {
              label: "Resend",
              onSelect: () => onResend(message.messageId),
              separatorBefore: true,
            },
          ]
        : []),
      ...(canReference
        ? [
            {
              label: pinned ? "Unpin" : "Pin",
              onSelect: () => onTogglePin(message),
              separatorBefore: true,
            },
          ]
        : []),
    ],
    [
      canReference,
      message,
      onReply,
      onResend,
      onTogglePin,
      pinned,
      text,
      toast,
    ],
  )

  return (
    <InlineContextMenu
      items={items}
      tabIndex={-1}
      aria-label="Message actions"
      data-inline-message-action="true"
      {...stylex.props(styles.trigger)}
    >
      {children}
    </InlineContextMenu>
  )
}

const styles = stylex.create({
  trigger: {
    maxWidth: "100%",
    borderRadius: 12,
    outline: "none",
    ":focus-visible": {
      outlineWidth: 2,
      outlineStyle: "solid",
      outlineColor: colors.accent,
      outlineOffset: 2,
    },
  },
})
