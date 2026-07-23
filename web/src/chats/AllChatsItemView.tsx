import {
  DbObjectKind,
  messageKey,
  type Chat,
  type Dialog,
  type Message,
  type Space,
  type User,
} from "@inline/client"
import { useLocation } from "@tanstack/react-router"
import * as stylex from "@stylexjs/stylex"
import { dialogPeerRoute } from "~/inline/data/peer"
import { useInlineObject } from "~/inline/data/react"
import { useInlineChatTitle } from "~/inline/data/useInlineChatTitle"
import { ThreadAvatar, UserAvatar } from "~/ui/Avatar"
import { colors } from "../styles/tokens.stylex"
import { allChatsRowTime } from "./AllChatsDate"
import { InlineChatLink } from "~/ui/InlineChatLink"

export type AllChatsRowLayout = "twoLine" | "titlePreviewLine"

export function AllChatsItemView({
  dialog,
  layout = "twoLine",
}: {
  dialog: Dialog
  layout?: AllChatsRowLayout
}) {
  const location = useLocation()
  const chat = useInlineObject<DbObjectKind.Chat, Chat>(DbObjectKind.Chat, dialog.chatId)
  const user = useInlineObject<DbObjectKind.User, User>(DbObjectKind.User, dialog.peerUserId)
  const lastMessageKey =
    chat?.lastMsgId == null ? undefined : messageKey(chat.id, chat.lastMsgId)
  const message = useInlineObject<DbObjectKind.Message, Message>(
    DbObjectKind.Message,
    lastMessageKey,
  )
  const sender = useInlineObject<DbObjectKind.User, User>(DbObjectKind.User, message?.fromId)
  const space = useInlineObject<DbObjectKind.Space, Space>(
    DbObjectKind.Space,
    dialog.spaceId ?? chat?.spaceId,
  )
  const peer = dialogPeerRoute(dialog)
  const path = `/chat/${peer.peerKind}/${peer.peerId}`
  const threadTitle = useInlineChatTitle(chat)
  const title =
    (user && ([user.firstName, user.lastName].filter(Boolean).join(" ") || user.username)) ||
    threadTitle
  const preview = message?.message?.replaceAll(/\s+/g, " ").trim() || "No messages"
  const senderName =
    !message?.out && !user
      ? [sender?.firstName, sender?.lastName].filter(Boolean).join(" ") || sender?.username
      : undefined
  const time = allChatsRowTime(message?.date ?? chat?.date ?? 0)
  const unread = Boolean(dialog.unreadMark || (dialog.unreadCount ?? 0) > 0)

  return (
    <InlineChatLink
      peer={peer}
      {...stylex.props(
        styles.row,
        layout === "titlePreviewLine" && styles.singleLineRow,
        location.pathname === path && styles.selected,
      )}
    >
      {unread ? <span {...stylex.props(styles.unreadDot)} /> : null}
      {user ? <UserAvatar user={user} size={30} /> : <ThreadAvatar emoji={chat?.emoji} size={30} />}
      <span
        {...stylex.props(
          styles.content,
          layout === "titlePreviewLine" && styles.singleLineContent,
        )}
      >
        <span {...stylex.props(styles.titleLine)}>
          <span {...stylex.props(styles.title, unread && styles.unreadTitle)}>{title}</span>
          {layout === "titlePreviewLine" ? (
            <span {...stylex.props(styles.inlinePreview)}>
              {senderName ? `${senderName}: ` : null}
              {message?.out ? "You: " : null}
              {preview}
            </span>
          ) : null}
          <span {...stylex.props(styles.trailing)}>
            {space?.name ? <span {...stylex.props(styles.space)}>{space.name}</span> : null}
            {space?.name && time ? <span>•</span> : null}
            {time ? <time>{time}</time> : null}
          </span>
        </span>
        {layout === "twoLine" ? (
          <span {...stylex.props(styles.previewLine)}>
            {senderName ? <span {...stylex.props(styles.sender)}>{senderName}: </span> : null}
            {message?.out ? "You: " : null}
            {preview}
          </span>
        ) : null}
      </span>
      {(dialog.unreadCount ?? 0) > 0 ? (
        <span {...stylex.props(styles.badge)}>{Math.min(dialog.unreadCount ?? 0, 99)}</span>
      ) : null}
    </InlineChatLink>
  )
}

const styles = stylex.create({
  row: {
    width: "calc(100% - 10px)",
    height: 50,
    position: "relative",
    display: "grid",
    gridTemplateColumns: "30px minmax(0, 1fr) auto",
    alignItems: "center",
    gap: 9,
    marginInline: 5,
    paddingInline: 8,
    borderRadius: 6,
    backgroundColor: {
      default: "transparent",
      ":hover": colors.hovered,
    },
    color: colors.textPrimary,
    textAlign: "left",
    textDecoration: "none",
  },
  singleLineRow: {
    height: 42,
  },
  selected: {
    backgroundColor: colors.selected,
  },
  unreadDot: {
    width: 5,
    height: 5,
    position: "absolute",
    left: 3,
    borderRadius: "50%",
    backgroundColor: colors.unread,
  },
  content: {
    minWidth: 0,
    display: "flex",
    flexDirection: "column",
    gap: 3,
  },
  singleLineContent: {
    display: "block",
  },
  titleLine: {
    minWidth: 0,
    display: "flex",
    alignItems: "baseline",
    gap: 8,
  },
  title: {
    minWidth: 0,
    overflow: "hidden",
    flex: 1,
    fontSize: 13,
    fontWeight: 500,
    textOverflow: "ellipsis",
    whiteSpace: "nowrap",
  },
  unreadTitle: {
    fontWeight: 650,
  },
  inlinePreview: {
    minWidth: 0,
    overflow: "hidden",
    flex: 2,
    color: colors.textSecondary,
    fontSize: 13,
    fontWeight: 400,
    textOverflow: "ellipsis",
    whiteSpace: "nowrap",
  },
  trailing: {
    maxWidth: 190,
    display: "flex",
    alignItems: "center",
    gap: 3,
    overflow: "hidden",
    flexShrink: 1,
    color: colors.textTertiary,
    fontSize: 11,
    whiteSpace: "nowrap",
  },
  space: {
    overflow: "hidden",
    paddingInline: 4,
    borderRadius: 4,
    textOverflow: "ellipsis",
  },
  previewLine: {
    minWidth: 0,
    overflow: "hidden",
    color: colors.textSecondary,
    fontSize: 13,
    textOverflow: "ellipsis",
    whiteSpace: "nowrap",
  },
  sender: {
    color: colors.textSecondary,
  },
  badge: {
    minWidth: 17,
    height: 17,
    display: "grid",
    placeItems: "center",
    paddingInline: 5,
    borderRadius: 9,
    backgroundColor: colors.unread,
    color: "#fff",
    fontSize: 10,
    fontWeight: 600,
  },
})
