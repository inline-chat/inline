import {
  DbObjectKind,
  messageKey,
  messageDraftKey,
  type Chat,
  type Dialog,
  type Message,
  type MessageDraft,
  type User,
} from "@inline/client"
import { useLocation } from "@tanstack/react-router"
import * as stylex from "@stylexjs/stylex"
import { useCallback, useMemo, useState, type FocusEvent } from "react"
import { dialogPeerRoute, messageDraftPeer } from "~/inline/data/peer"
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
import type { DialogID } from "@inline/ids"
import { chatListPreview } from "~/chats/ChatListPreview"

export function SidebarChatItem({
  dialog,
  large = true,
  depth = 0,
  childCount = 0,
  expanded = false,
  detached = false,
  closeGroupDialogs,
  onClose,
  onToggleExpanded = () => undefined,
  onTogglePinned,
  onToggleRead,
}: {
  dialog: Dialog
  large?: boolean
  depth?: number
  childCount?: number
  expanded?: boolean
  detached?: boolean
  closeGroupDialogs?: readonly Dialog[]
  onClose: (dialog: Dialog, closeGroupDialogs?: readonly Dialog[]) => void
  onToggleExpanded?: (dialogId: DialogID) => void
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
  const draft = useInlineObject<DbObjectKind.MessageDraft, MessageDraft>(
    DbObjectKind.MessageDraft,
    messageDraftKey(messageDraftPeer(peer)),
  )
  const sender = useInlineObject<DbObjectKind.User, User>(
    DbObjectKind.User,
    message?.fromId,
  )
  const path = `/chat/${peer.peerKind}/${peer.peerId}`
  const selected = location.pathname === path
  const threadTitle = useInlineChatTitle(chat)
  const title = user
    ? [user.firstName, user.lastName].filter(Boolean).join(" ") || user.username
    : threadTitle
  const unread = Boolean(dialog.unreadMark || (dialog.unreadCount ?? 0) > 0)
  const senderName =
    !message?.out && !user
      ? [sender?.firstName, sender?.lastName].filter(Boolean).join(" ") ||
        sender?.username
      : undefined
  const preview = chatListPreview({
    message,
    draft,
    senderName,
    replyThread: chat?.parentChatId != null,
  })
  const canClose = !dialog.pinned
  const requestClose = useCallback(() => {
    if (closeGroupDialogs) onClose(dialog, closeGroupDialogs)
    else onClose(dialog)
  }, [closeGroupDialogs, dialog, onClose])
  const menuItems = useMemo<readonly InlineContextMenuItem[]>(
    () => [
      ...(canClose
        ? [
            {
              label: "Close from Sidebar",
              onSelect: requestClose,
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
    [canClose, dialog, onTogglePinned, onToggleRead, requestClose, unread],
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
      data-inline-sidebar-depth={depth}
      data-inline-sidebar-detached={detached ? "true" : "false"}
      onPointerEnter={() => setShowsCloseControl(true)}
      onPointerLeave={() => setShowsCloseControl(false)}
      onFocusCapture={() => setShowsCloseControl(true)}
      onBlurCapture={blurContainer}
      {...stylex.props(styles.container)}
    >
      {childCount > 0 ? (
        <button
          type="button"
          aria-label={expanded ? `Collapse ${title}` : `Expand ${title}`}
          aria-expanded={expanded}
          style={{ left: 7 + depth * 13 }}
          onClick={(event) => {
            event.preventDefault()
            event.stopPropagation()
            onToggleExpanded(dialog.id)
          }}
          {...stylex.props(
            styles.disclosure,
            !large && styles.disclosureCompact,
            !expanded && styles.disclosureCollapsed,
          )}
        >
          <Icon name="chevronDown" size={10} />
        </button>
      ) : null}
      <InlineChatLink
        peer={peer}
        style={{ paddingInlineStart: 9 + depth * 13 }}
        {...stylex.props(styles.row, !large && styles.compact, selected && styles.selected)}
      >
        {unread ? <span {...stylex.props(styles.unreadDot)} /> : null}
        <span aria-hidden="true" {...stylex.props(styles.treeControl)} />
        {user ? (
          <UserAvatar user={user} size={large ? 32 : 22} />
        ) : (
          <ThreadAvatar emoji={chat?.emoji} size={large ? 32 : 22} />
        )}
        <span {...stylex.props(styles.content)}>
          <span {...stylex.props(styles.title, unread && styles.unreadTitle)}>{title}</span>
          {large ? (
            <span {...stylex.props(styles.preview)}>{preview}</span>
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
          onClick={requestClose}
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
    gridTemplateColumns: `12px ${metrics.sidebarIconSize} minmax(0, 1fr) auto`,
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
    gridTemplateColumns: "12px 22px minmax(0, 1fr) auto",
  },
  treeControl: {
    width: 12,
    height: 18,
    display: "grid",
    placeItems: "center",
  },
  disclosure: {
    width: 18,
    height: 18,
    position: "absolute",
    zIndex: 2,
    top: 14,
    display: "grid",
    placeItems: "center",
    padding: 0,
    borderWidth: 0,
    borderRadius: 4,
    backgroundColor: "transparent",
    color: colors.textTertiary,
    transitionProperty: "transform",
    transitionDuration: "120ms",
  },
  disclosureCompact: {
    top: 6,
  },
  disclosureCollapsed: {
    transform: "rotate(-90deg)",
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
