import { DbObjectKind, type Message, type User } from "@inline/client"
import type { MessageID, UserID } from "@inline/ids"
import * as stylex from "@stylexjs/stylex"
import { useState } from "react"
import { useInlineObject } from "~/inline/data/react"
import { Icon } from "~/ui/Icon"
import { colors } from "../styles/tokens.stylex"
import { makeMessagePresentation } from "./MessageContent"
import { useInlineToast } from "~/ui/InlineToast"

export type PinnedMessageHeaderPresentation = {
  label: string
  senderId?: UserID
}

export const makePinnedMessageHeaderPresentation = (
  message?: Message,
): PinnedMessageHeaderPresentation => {
  if (!message) return { label: "Pinned message unavailable" }
  const presentation = makeMessagePresentation(message)
  return {
    label:
      presentation.text ??
      presentation.media?.label ??
      presentation.service ??
      presentation.fallback ??
      "Pinned message unavailable",
    senderId: message.fromId,
  }
}

export function PinnedMessageHeaderView({
  messageId,
  presentation,
  onOpen,
  onUnpin,
}: {
  messageId: MessageID
  presentation: PinnedMessageHeaderPresentation
  onOpen: (messageId: MessageID) => void
  onUnpin: (messageId: MessageID) => Promise<void>
}) {
  const [unpinPending, setUnpinPending] = useState(false)
  const toast = useInlineToast()
  const sender = useInlineObject<DbObjectKind.User, User>(
    DbObjectKind.User,
    presentation.senderId,
  )
  const senderName =
    [sender?.firstName, sender?.lastName].filter(Boolean).join(" ") ||
    sender?.username ||
    "Pinned message"

  return (
    <div {...stylex.props(styles.root)}>
      <div {...stylex.props(styles.surface)}>
        <button
          type="button"
          aria-label="Go to pinned message"
          onClick={() => onOpen(messageId)}
          {...stylex.props(styles.content)}
        >
          <span {...stylex.props(styles.copy)}>
            <span {...stylex.props(styles.sender)}>{senderName}</span>
            <span {...stylex.props(styles.message)}>
              {presentation.label}
            </span>
          </span>
        </button>
        <button
          type="button"
          aria-label="Unpin"
          title="Unpin"
          disabled={unpinPending}
          onClick={() => {
            if (unpinPending) return
            setUnpinPending(true)
            void onUnpin(messageId)
              .catch((cause: unknown) => {
                console.error("Could not unpin Inline message", cause)
                toast.show("Could not unpin message", "error")
              })
              .finally(() => setUnpinPending(false))
          }}
          {...stylex.props(styles.unpin)}
        >
          <Icon name="xmark" size={12} />
        </button>
      </div>
    </div>
  )
}

const styles = stylex.create({
  root: {
    height: 42,
    flexShrink: 0,
    paddingBlock: 2,
    paddingInline: 8,
    backgroundColor: colors.content,
  },
  surface: {
    width: "100%",
    height: 38,
    display: "flex",
    alignItems: "center",
    borderRadius: 14,
    borderWidth: 1,
    borderStyle: "solid",
    borderColor: "light-dark(rgba(255,255,255,.55), rgba(255,255,255,.08))",
    backgroundColor: "light-dark(rgba(241,241,243,.84), rgba(48,48,52,.82))",
    boxShadow: "0 1px 2px light-dark(rgba(0,0,0,.05), rgba(0,0,0,.22))",
    backdropFilter: "blur(18px) saturate(1.2)",
  },
  content: {
    minWidth: 0,
    height: 38,
    display: "flex",
    alignItems: "center",
    flex: 1,
    paddingInline: 16,
    borderWidth: 0,
    backgroundColor: "transparent",
    color: colors.textPrimary,
    font: "inherit",
    textAlign: "start",
    cursor: "pointer",
    borderRadius: 13,
    ":hover": {
      backgroundColor: "light-dark(rgba(0,0,0,.035), rgba(255,255,255,.055))",
    },
  },
  unpin: {
    width: 38,
    height: 38,
    display: "grid",
    placeItems: "center",
    flexShrink: 0,
    padding: 0,
    borderWidth: 0,
    borderRadius: 10,
    backgroundColor: "transparent",
    color: colors.textSecondary,
    cursor: "pointer",
    ":disabled": {
      color: colors.textTertiary,
      cursor: "default",
    },
    ":hover": {
      backgroundColor: "light-dark(rgba(0,0,0,.08), rgba(255,255,255,.1))",
      color: colors.textPrimary,
    },
  },
  copy: {
    minWidth: 0,
    display: "flex",
    flexDirection: "column",
    gap: 1,
  },
  sender: {
    overflow: "hidden",
    color: colors.textPrimary,
    fontSize: 10,
    fontWeight: 600,
    lineHeight: 1.15,
    textOverflow: "ellipsis",
    whiteSpace: "nowrap",
  },
  message: {
    overflow: "hidden",
    color: colors.textSecondary,
    fontSize: 10,
    lineHeight: 1.15,
    textOverflow: "ellipsis",
    whiteSpace: "nowrap",
  },
})
