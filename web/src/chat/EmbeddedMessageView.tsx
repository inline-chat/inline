import { DbObjectKind, type User } from "@inline/client"
import * as stylex from "@stylexjs/stylex"
import { useInlineObject } from "~/inline/data/react"
import type { MessageID } from "@inline/ids"
import { colors } from "../styles/tokens.stylex"
import type { ChatMessageEmbeddedReply } from "./ChatRowListModel"

const contentLabel = (reply: ChatMessageEmbeddedReply) =>
  reply.presentation?.text ??
  reply.presentation?.media?.label ??
  reply.presentation?.service ??
  reply.presentation?.fallback ??
  "Loading message…"

export function EmbeddedMessageView({
  reply,
  outgoing,
  onOpen,
}: {
  reply: ChatMessageEmbeddedReply
  outgoing: boolean
  onOpen: (messageId: MessageID) => void
}) {
  const sender = useInlineObject<DbObjectKind.User, User>(
    DbObjectKind.User,
    reply.fromId,
  )
  const senderName =
    [sender?.firstName, sender?.lastName].filter(Boolean).join(" ") ||
    sender?.username ||
    "User"

  return (
    <button
      type="button"
      aria-label={`Go to message from ${senderName}`}
      onClick={() => onOpen(reply.messageId)}
      {...stylex.props(
        styles.root,
        outgoing ? styles.outgoing : styles.incoming,
      )}
    >
      <span aria-hidden="true" {...stylex.props(styles.bar)} />
      <span {...stylex.props(styles.copy)}>
        <span {...stylex.props(styles.sender)}>{senderName}</span>
        <span {...stylex.props(styles.message)}>{contentLabel(reply)}</span>
      </span>
    </button>
  )
}

const styles = stylex.create({
  root: {
    width: "100%",
    minWidth: 150,
    height: 38,
    display: "flex",
    alignItems: "stretch",
    gap: 7,
    padding: 5,
    borderWidth: 0,
    borderRadius: 8,
    color: "inherit",
    font: "inherit",
    textAlign: "start",
    cursor: "pointer",
  },
  incoming: {
    backgroundColor: "light-dark(rgba(255,255,255,.58), rgba(0,0,0,.14))",
  },
  outgoing: {
    backgroundColor: "rgba(255,255,255,.14)",
  },
  bar: {
    width: 3,
    flexShrink: 0,
    borderRadius: 2,
    backgroundColor: colors.accent,
  },
  copy: {
    minWidth: 0,
    display: "flex",
    flex: 1,
    flexDirection: "column",
    justifyContent: "center",
    gap: 1,
  },
  sender: {
    overflow: "hidden",
    color: "inherit",
    fontSize: 10,
    fontWeight: 600,
    lineHeight: 1.15,
    textOverflow: "ellipsis",
    whiteSpace: "nowrap",
  },
  message: {
    overflow: "hidden",
    opacity: 0.72,
    fontSize: 10,
    lineHeight: 1.15,
    textOverflow: "ellipsis",
    whiteSpace: "nowrap",
  },
})
