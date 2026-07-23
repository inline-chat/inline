import { DbObjectKind, MessageSendingStatus, type User } from "@inline/client"
import * as stylex from "@stylexjs/stylex"
import { useInlineObject } from "~/inline/data/react"
import { colors, metrics } from "../styles/tokens.stylex"
import { UserAvatar } from "~/ui/Avatar"
import { MessageBubble } from "./MessageBubble"
import { MessageDateSeparator } from "./MessageDateSeparator"
import { MessageServiceRow } from "./MessageServiceRow"
import { MessageUnreadSeparator } from "./MessageUnreadSeparator"
import type { ChatMessageRow } from "./ChatRowListModel"
import type { ChatID, MessageID, UserID } from "@inline/ids"
import type { InlinePeerRoute } from "~/inline/data/peer"
import { MessageContextMenu } from "./MessageContextMenu"
import type { InlineMessageStyle } from "~/inline/preferences/InlineAppearancePreferences"

const sameGroup = (
  first?: ChatMessageRow,
  second?: ChatMessageRow,
) =>
  Boolean(
    first &&
      second &&
      !first.presentation.service &&
      !second.presentation.service &&
      first.fromId === second.fromId &&
      Math.abs((first.date ?? 0) - (second.date ?? 0)) < 5 * 60,
  )

const startsNewDay = (previous?: number, current?: number) => {
  if (!current) return false
  if (!previous) return true
  return new Date(previous * 1_000).toDateString() !==
    new Date(current * 1_000).toDateString()
}

export function MessageRow({
  message,
  previous,
  next,
  showParticipants,
  highlighted,
  unreadBefore,
  firstInList,
  lastInList,
  onOpenMessage,
  onOpenReplyThread,
  onResendMessage,
  onReplyMessage,
  onTogglePinMessage,
  pinned,
  peer,
  currentUserId,
  messageStyle,
}: {
  message: ChatMessageRow
  previous?: ChatMessageRow
  next?: ChatMessageRow
  showParticipants: boolean
  highlighted?: boolean
  unreadBefore?: boolean
  firstInList: boolean
  lastInList: boolean
  onOpenMessage: (messageId: MessageID) => void
  onOpenReplyThread: (chatId: ChatID) => void
  onResendMessage: (messageId: MessageID) => void
  onReplyMessage: (message: ChatMessageRow) => void
  onTogglePinMessage: (message: ChatMessageRow) => void
  pinned: boolean
  peer: InlinePeerRoute
  currentUserId: UserID
  messageStyle: InlineMessageStyle
}) {
  const minimal = messageStyle === "minimal"
  const user = useInlineObject<DbObjectKind.User, User>(DbObjectKind.User, message.fromId)
  const startsGroup = !sameGroup(previous, message)
  const endsGroup = !sameGroup(message, next)
  const participantLayout = minimal || (!message.out && showParticipants)
  const senderName = [user?.firstName, user?.lastName].filter(Boolean).join(" ") || user?.username
  const dateSeparator = startsNewDay(previous?.date, message.date)
  const optimisticSending =
    message.out && message.status === MessageSendingStatus.Sending

  return (
    <div
      data-message-id={message.messageId}
      data-highlighted={highlighted || undefined}
      {...stylex.props(
        styles.item,
        firstInList && styles.firstItem,
        lastInList && styles.lastItem,
        highlighted && styles.highlighted,
      )}
    >
      {unreadBefore ? <MessageUnreadSeparator /> : null}
      {dateSeparator && message.date ? <MessageDateSeparator date={message.date} /> : null}
      {message.presentation.service ? (
        <MessageServiceRow label={message.presentation.service} />
      ) : (
        <div
          data-inline-optimistic-send={optimisticSending || undefined}
          {...stylex.props(
            styles.row,
            minimal
              ? styles.minimalRow
              : message.out
                ? styles.outgoingRow
                : styles.incomingRow,
            startsGroup && styles.groupStart,
            minimal && styles.minimalGroup,
            optimisticSending && styles.optimisticSending,
          )}
        >
          {participantLayout ? (
            <span {...stylex.props(styles.avatarSlot, minimal && styles.minimalAvatarSlot)}>
              {(minimal ? startsGroup : endsGroup) ? (
                <UserAvatar user={user} size={minimal ? 30 : 28} />
              ) : null}
            </span>
          ) : null}
          <div
            {...stylex.props(
              styles.content,
              message.out && !minimal && styles.outgoingContent,
              minimal && styles.minimalContent,
            )}
          >
            {participantLayout && startsGroup && senderName ? (
              <span {...stylex.props(styles.sender, minimal && styles.minimalSender)}>{senderName}</span>
            ) : null}
            <MessageContextMenu
              message={message}
              pinned={pinned}
              onReply={onReplyMessage}
              onTogglePin={onTogglePinMessage}
              onResend={onResendMessage}
            >
              <MessageBubble
                message={message}
                style={messageStyle}
                onOpenMessage={onOpenMessage}
                onOpenReplyThread={onOpenReplyThread}
                onResendMessage={onResendMessage}
                peer={peer}
                currentUserId={currentUserId}
              />
            </MessageContextMenu>
          </div>
        </div>
      )}
    </div>
  )
}

const styles = stylex.create({
  item: {
    borderRadius: 8,
    transitionProperty: "background-color",
    transitionDuration: "180ms",
  },
  firstItem: {
    paddingTop: 14,
  },
  lastItem: {
    paddingBottom: 10,
  },
  highlighted: {
    backgroundColor: "light-dark(rgba(123, 91, 228, .13), rgba(155, 130, 239, .17))",
  },
  row: {
    width: "100%",
    display: "flex",
    alignItems: "flex-end",
    gap: 8,
    paddingInline: metrics.messageSideInset,
    paddingBlock: 1,
  },
  incomingRow: {
    justifyContent: "flex-start",
  },
  outgoingRow: {
    justifyContent: "flex-end",
  },
  minimalRow: {
    justifyContent: "flex-start",
    alignItems: "flex-start",
    paddingInline: 24,
  },
  groupStart: {
    paddingTop: 8,
  },
  minimalGroup: {
    paddingTop: 8,
  },
  optimisticSending: {
    animationName: stylex.keyframes({
      from: {
        opacity: 0,
        transform: "translateY(5px) scale(.985)",
      },
      to: {
        opacity: 1,
        transform: "translateY(0) scale(1)",
      },
    }),
    animationDuration: {
      default: "160ms",
      "@media (prefers-reduced-motion: reduce)": "0ms",
    },
    animationTimingFunction: "cubic-bezier(.2, .8, .2, 1)",
    animationFillMode: "both",
  },
  avatarSlot: {
    width: metrics.messageAvatarSize,
    height: metrics.messageAvatarSize,
    display: "block",
    flexShrink: 0,
  },
  minimalAvatarSlot: {
    width: 30,
    height: 30,
  },
  content: {
    minWidth: 0,
    display: "flex",
    flexDirection: "column",
    alignItems: "flex-start",
  },
  outgoingContent: {
    alignItems: "flex-end",
  },
  minimalContent: {
    maxWidth: "min(720px, calc(100% - 52px))",
    alignItems: "stretch",
  },
  sender: {
    marginInline: 9,
    marginBottom: 3,
    color: colors.textSecondary,
    fontSize: 11,
    fontWeight: 500,
  },
  minimalSender: {
    marginInline: 0,
    marginBottom: 2,
    color: colors.textPrimary,
    fontSize: 12,
    fontWeight: 600,
  },
})
