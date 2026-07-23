import {
  DbObjectKind,
  type Chat,
  type User,
} from "@inline/client"
import { useNavigate } from "@tanstack/react-router"
import * as stylex from "@stylexjs/stylex"
import type { MessageID, UserID } from "@inline/ids"
import { useInlineObject } from "~/inline/data/react"
import type { InlinePeerRoute } from "~/inline/data/peer"
import { colors } from "../styles/tokens.stylex"
import type { ChatMessageForwardHeader } from "./ChatRowListModel"
import { forwardTargetPeer } from "./ForwardNavigation"

const userName = (user?: User) =>
  [user?.firstName, user?.lastName].filter(Boolean).join(" ") ||
  user?.username

const samePeer = (left: InlinePeerRoute, right: InlinePeerRoute) =>
  left.peerKind === right.peerKind && left.peerId === right.peerId

export function ForwardHeaderView({
  forward,
  currentPeer,
  onOpenMessage,
  currentUserId,
}: {
  forward: ChatMessageForwardHeader
  currentPeer: InlinePeerRoute
  onOpenMessage: (messageId: MessageID) => void
  currentUserId: UserID
}) {
  const navigate = useNavigate()
  const peerUser = useInlineObject<DbObjectKind.User, User>(
    DbObjectKind.User,
    forward.fromPeer?.peerKind === "user"
      ? forward.fromPeer.peerId
      : undefined,
  )
  const sender = useInlineObject<DbObjectKind.User, User>(
    DbObjectKind.User,
    forward.fromId,
  )
  const thread = useInlineObject<DbObjectKind.Chat, Chat>(
    DbObjectKind.Chat,
    forward.fromPeer?.peerKind === "chat"
      ? forward.fromPeer.peerId
      : undefined,
  )
  const sourceUser = sender ?? peerUser
  const isPrivate =
    forward.fromPeer?.peerKind === "chat"
      ? !thread
      : forward.fromPeer?.peerKind === "user"
        ? !sourceUser
        : true
  const title =
    forward.fromPeer?.peerKind === "chat"
      ? thread?.title?.trim() || "Untitled"
      : userName(sourceUser) || "User"
  const label = isPrivate
    ? "Forwarded from a private chat"
    : `Forwarded from: ${title}`

  const open = () => {
    const messageId = forward.fromMessageId
    if (!messageId) return
    const targetPeer = forwardTargetPeer(
      forward,
      currentPeer,
      currentUserId,
    )
    if (samePeer(targetPeer, currentPeer)) {
      onOpenMessage(messageId)
      return
    }
    void navigate({
      to: "/chat/$peerKind/$peerId",
      params: {
        peerKind: targetPeer.peerKind,
        peerId: targetPeer.peerId,
      },
      search: isPrivate ? {} : { messageId },
    })
  }

  return (
    <button
      type="button"
      disabled={!forward.fromMessageId}
      onClick={open}
      aria-label={label}
      {...stylex.props(styles.root)}
    >
      {label}
    </button>
  )
}

const styles = stylex.create({
  root: {
    maxWidth: "100%",
    height: 16,
    display: "block",
    overflow: "hidden",
    padding: 0,
    borderWidth: 0,
    backgroundColor: "transparent",
    color: colors.accent,
    font: "inherit",
    fontSize: 11,
    fontWeight: 500,
    lineHeight: "16px",
    textAlign: "start",
    textOverflow: "ellipsis",
    whiteSpace: "nowrap",
    cursor: "pointer",
  },
})
