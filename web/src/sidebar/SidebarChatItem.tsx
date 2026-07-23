import {
  DbObjectKind,
  messageKey,
  type Chat,
  type Dialog,
  type Message,
  type User,
} from "@inline/client"
import { useLocation } from "@tanstack/react-router"
import * as stylex from "@stylexjs/stylex"
import { useMemo, useState, type FocusEvent } from "react"
import { dialogPeerRoute } from "~/inline/data/peer"
import { useInlineObject } from "~/inline/data/react"
import { useInlineChatTitle } from "~/inline/data/useInlineChatTitle"
import { colors, metrics, typography } from "../styles/tokens.stylex"
import { ThreadAvatar, UserAvatar } from "~/ui/Avatar"
import { Icon } from "~/ui/Icon"
import {
  InlineContextMenu,
  type InlineContextMenuItem,
} from "~/ui/InlineContextMenu"
import { InlineChatLink } from "~/ui/InlineChatLink"

export function SidebarChatItem({
  dialog,
  large = true,
  onClose,
  onTogglePinned,
  onToggleRead,
}: {
  dialog: Dialog
  large?: boolean
  onClose: (dialog: Dialog) => void
  onTogglePinned: (dialog: Dialog) => void
  onToggleRead: (dialog: Dialog) => void
}) {
  const location = useLocation()
  const [showsCloseControl, setShowsCloseControl] = useState(false)
  const chat = useInlineObject<DbObjectKind.Chat, Chat>(DbObjectKind.Chat, dialog.chatId)
  const user = useInlineObject<DbObjectKind.User, User>(DbObjectKind.User, dialog.peerUserId)
  const lastMessageKey =
    chat?.lastMsgId == null ? undefined : messageKey(chat.id, chat.lastMsgId)
  const message = useInlineObject<DbObjectKind.Message, Message>(
    DbObjectKind.Message,
    lastMessageKey,
  )
  const peer = dialogPeerRoute(dialog)
  const path = `/chat/${peer.peerKind}/${peer.peerId}`
  const selected = location.pathname === path
  const threadTitle = useInlineChatTitle(chat)
  const title = user
    ? [user.firstName, user.lastName].filter(Boolean).join(" ") || user.username
    : threadTitle
  const unread = Boolean(dialog.unreadMark || (dialog.unreadCount ?? 0) > 0)
  const canClose = !dialog.pinned
  const menuItems = useMemo<readonly InlineContextMenuItem[]>(
    () => [
      ...(canClose
        ? [
            {
              label: "Close from Sidebar",
              onSelect: () => onClose(dialog),
            },
          ]
        : []),
      {
        label: dialog.pinned ? "Unpin" : "Pin",
        onSelect: () => onTogglePinned(dialog),
        separatorBefore: canClose,
      },
      {
        label: unread ? "Mark Read" : "Mark Unread",
        onSelect: () => onToggleRead(dialog),
      },
    ],
    [canClose, dialog, onClose, onTogglePinned, onToggleRead, unread],
  )
  const blurContainer = (event: FocusEvent<HTMLDivElement>) => {
    if (
      !event.currentTarget.contains(
        event.relatedTarget as Node | null,
      )
    ) {
      setShowsCloseControl(false)
    }
  }

  return (
    <InlineContextMenu
      items={menuItems}
      data-inline-sidebar-chat-id={dialog.chatId}
      data-inline-dialog-unread={unread ? "true" : "false"}
      data-inline-dialog-pinned={dialog.pinned ? "true" : "false"}
      onPointerEnter={() => setShowsCloseControl(true)}
      onPointerLeave={() => setShowsCloseControl(false)}
      onFocusCapture={() => setShowsCloseControl(true)}
      onBlurCapture={blurContainer}
      {...stylex.props(styles.container)}
    >
      <InlineChatLink
        peer={peer}
        {...stylex.props(styles.row, !large && styles.compact, selected && styles.selected)}
      >
        {unread ? <span {...stylex.props(styles.unreadDot)} /> : null}
        {user ? (
          <UserAvatar user={user} size={large ? 32 : 22} />
        ) : (
          <ThreadAvatar emoji={chat?.emoji} size={large ? 32 : 22} />
        )}
        <span {...stylex.props(styles.content)}>
          <span {...stylex.props(styles.title, unread && styles.unreadTitle)}>{title}</span>
          {large && message?.message ? (
            <span {...stylex.props(styles.preview)}>{message.out ? `You: ${message.message}` : message.message}</span>
          ) : null}
        </span>
        {!showsCloseControl && (dialog.unreadCount ?? 0) > 0 ? (
          <span {...stylex.props(styles.badge)}>{Math.min(dialog.unreadCount ?? 0, 99)}</span>
        ) : null}
      </InlineChatLink>
      {canClose ? (
        <button
          type="button"
          aria-label={`Close ${title || "chat"} from sidebar`}
          title="Close"
          tabIndex={0}
          onClick={() => onClose(dialog)}
          {...stylex.props(
            styles.close,
            !large && styles.closeCompact,
            !showsCloseControl && styles.closeHidden,
          )}
        >
          <Icon name="xmark" size={10} />
        </button>
      ) : null}
    </InlineContextMenu>
  )
}

const styles = stylex.create({
  container: {
    width: `calc(100% - ${metrics.sidebarOuterInset} * 2)`,
    position: "relative",
    marginInline: metrics.sidebarOuterInset,
    borderRadius: metrics.sidebarRadius,
  },
  row: {
    width: "100%",
    height: metrics.sidebarRowHeight,
    position: "relative",
    display: "grid",
    gridTemplateColumns: `${metrics.sidebarIconSize} minmax(0, 1fr) auto`,
    alignItems: "center",
    gap: 8,
    marginInline: 0,
    paddingInline: metrics.sidebarInnerInset,
    borderRadius: metrics.sidebarRadius,
    backgroundColor: {
      default: "transparent",
      ":hover": colors.hovered,
    },
    color: colors.textPrimary,
    textAlign: "left",
    textDecoration: "none",
  },
  compact: {
    height: 30,
    gridTemplateColumns: "22px minmax(0, 1fr) auto",
  },
  selected: {
    backgroundColor: colors.selected,
  },
  unreadDot: {
    width: 5,
    height: 5,
    position: "absolute",
    left: 4,
    borderRadius: "50%",
    backgroundColor: colors.unread,
  },
  content: {
    minWidth: 0,
    display: "flex",
    flexDirection: "column",
    gap: 2,
    overflow: "hidden",
  },
  title: {
    overflow: "hidden",
    color: colors.textPrimary,
    fontSize: typography.sidebarTitle,
    fontWeight: 400,
    lineHeight: 1.2,
    textOverflow: "ellipsis",
    whiteSpace: "nowrap",
  },
  unreadTitle: {
    fontWeight: 600,
  },
  preview: {
    overflow: "hidden",
    color: colors.textTertiary,
    fontSize: typography.sidebarPreview,
    lineHeight: 1.2,
    textOverflow: "ellipsis",
    whiteSpace: "nowrap",
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
  close: {
    width: 17,
    height: 17,
    position: "absolute",
    zIndex: 1,
    top: 7,
    right: 8,
    display: "grid",
    placeItems: "center",
    padding: 0,
    borderWidth: 0,
    borderRadius: "50%",
    backgroundColor: {
      default: "transparent",
      ":hover": colors.hovered,
    },
    color: colors.textSecondary,
  },
  closeCompact: {
    top: 6,
  },
  closeHidden: {
    opacity: 0,
    pointerEvents: "none",
  },
})
