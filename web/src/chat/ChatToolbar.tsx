import {
  DbObjectKind,
  type Chat,
  type Dialog,
  type User,
  useRealtimeClient,
} from "@inline/client"
import { DialogFollowMode } from "@inline-chat/protocol/core"
import type { ChatID, DialogID, UserID } from "@inline/ids"
import * as stylex from "@stylexjs/stylex"
import { useInlineObject } from "~/inline/data/react"
import { useInlineChatTitle } from "~/inline/data/useInlineChatTitle"
import { colors, metrics } from "../styles/tokens.stylex"
import { ThreadAvatar, UserAvatar } from "~/ui/Avatar"
import { Icon } from "~/ui/Icon"
import { useState } from "react"
import type { InlinePeerRoute } from "~/inline/data/peer"
import { InlineMenu, type InlineMenuItem } from "~/ui/InlineMenu"
import { useInlineToast } from "~/ui/InlineToast"
import { writeInlineClipboardText } from "~/ui/InlineClipboard"
import { inlinePeerDeepLink } from "~/inline/navigation/InlineDeepLink"
import {
  toggleSidebarChatPinned,
  toggleSidebarChatRead,
} from "~/sidebar/SidebarChatActions"
import {
  chatToolbarFollowPresentation,
  toggleReplyThreadFollow,
} from "./ChatToolbarFollowAction"
import { InlineNavigationControls } from "~/ui/InlineNavigationControls"

export function ChatToolbar({
  peer,
  peerUserId,
  chatId,
  dialogId,
}: {
  peer: InlinePeerRoute
  peerUserId?: UserID
  chatId?: ChatID
  dialogId?: DialogID
}) {
  const chat = useInlineObject<DbObjectKind.Chat, Chat>(
    DbObjectKind.Chat,
    chatId,
  )
  const dialog = useInlineObject<DbObjectKind.Dialog, Dialog>(
    DbObjectKind.Dialog,
    dialogId,
  )
  const user = useInlineObject<DbObjectKind.User, User>(DbObjectKind.User, peerUserId)
  const realtime = useRealtimeClient()
  const [followPending, setFollowPending] = useState(false)
  const toast = useInlineToast()
  const threadTitle = useInlineChatTitle(chat)
  const title = user
    ? [user.firstName, user.lastName].filter(Boolean).join(" ") || user.username
    : threadTitle
  const replyThread =
    chat?.parentChatId != null && chat.parentMessageId != null && dialog != null
  const followPresentation = chatToolbarFollowPresentation(
    dialog?.followMode === DialogFollowMode.FOLLOWING,
  )
  const toggleFollow = () => {
    if (!dialog || followPending) return
    setFollowPending(true)
    void toggleReplyThreadFollow({ dialog, realtime })
      .catch((cause: unknown) => {
        console.error("Could not update Inline reply-thread follow mode", cause)
        toast.show("Could not update follow mode", "error")
      })
      .finally(() => setFollowPending(false))
  }
  const unread = Boolean(dialog?.unreadMark || (dialog?.unreadCount ?? 0) > 0)
  const runDialogAction = (action: () => Promise<unknown>, failure: string) => {
    void action().catch((cause: unknown) => {
      console.error(failure, cause)
      toast.show(failure, "error")
    })
  }
  const menuItems: InlineMenuItem[] = [
    {
      label: "Copy Link",
      icon: "link",
      onSelect: () => {
        void writeInlineClipboardText(inlinePeerDeepLink(peer))
          .then(() => toast.show("Copied link"))
          .catch(() => toast.show("Could not copy link", "error"))
      },
    },
  ]
  if (dialog) {
    menuItems.push(
      {
        label: dialog.pinned ? "Unpin" : "Pin",
        icon: "pin",
        separatorBefore: true,
        onSelect: () =>
          runDialogAction(
            () => toggleSidebarChatPinned({ dialog, realtime }),
            "Could not update pin",
          ),
      },
      {
        label: unread ? "Mark Read" : "Mark Unread",
        icon: "bubble",
        onSelect: () =>
          runDialogAction(
            () => toggleSidebarChatRead({ dialog, realtime }),
            "Could not update read state",
          ),
      },
    )
  }

  return (
    <header {...stylex.props(styles.root)}>
      <InlineNavigationControls />
      {user ? <UserAvatar user={user} size={28} /> : <ThreadAvatar emoji={chat?.emoji} size={28} />}
      <div {...stylex.props(styles.titleBlock)}>
        <h1 {...stylex.props(styles.title)}>{title}</h1>
      </div>
      {replyThread ? (
        <button
          type="button"
          aria-label={followPresentation.title}
          title={followPresentation.tooltip}
          disabled={followPending}
          onClick={toggleFollow}
          {...stylex.props(styles.action, styles.trailingAction)}
        >
          <Icon name={followPresentation.icon} size={16} />
        </button>
      ) : null}
      <InlineMenu
        align="end"
        trigger={
          <button
            type="button"
            aria-label="More"
            title="More"
            {...stylex.props(styles.action, !replyThread && styles.trailingAction)}
          >
            <Icon name="more" size={16} />
          </button>
        }
        items={menuItems}
      />
    </header>
  )
}

const styles = stylex.create({
  root: {
    height: metrics.toolbarHeight,
    display: "flex",
    alignItems: "center",
    gap: 8,
    paddingInline: 14,
    borderBottomWidth: 1,
    borderBottomStyle: "solid",
    borderBottomColor: colors.separator,
    flexShrink: 0,
    backgroundColor: colors.content,
    WebkitAppRegion: "drag",
  },
  titleBlock: {
    minWidth: 0,
    display: "flex",
    flexDirection: "column",
  },
  action: {
    width: 28,
    height: 28,
    display: "grid",
    placeItems: "center",
    padding: 0,
    borderWidth: 0,
    borderRadius: 6,
    backgroundColor: {
      default: "transparent",
      ":hover": colors.hovered,
    },
    color: colors.textSecondary,
    WebkitAppRegion: "no-drag",
    ":disabled": {
      color: colors.textTertiary,
    },
  },
  trailingAction: {
    marginInlineStart: "auto",
  },
  title: {
    margin: 0,
    overflow: "hidden",
    fontSize: 13,
    fontWeight: 600,
    lineHeight: 1.15,
    textOverflow: "ellipsis",
    whiteSpace: "nowrap",
  },
})
