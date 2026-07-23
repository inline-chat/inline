import { MessageSendingStatus } from "@inline/client"
import * as stylex from "@stylexjs/stylex"
import { colors, metrics } from "../styles/tokens.stylex"
import { MessageContentView } from "./MessageContentView"
import type { ChatMessageRow } from "./ChatRowListModel"
import type { ChatID, MessageID, UserID } from "@inline/ids"
import { EmbeddedMessageView } from "./EmbeddedMessageView"
import { ReplyThreadSummaryView } from "./ReplyThreadSummaryView"
import { ForwardHeaderView } from "./ForwardHeaderView"
import type { InlinePeerRoute } from "~/inline/data/peer"
import { MessageReactionsView } from "./MessageReactionsView"
import type { InlineMessageStyle } from "~/inline/preferences/InlineAppearancePreferences"

const messageTime = (date?: number) => {
  if (!date) return ""
  return new Intl.DateTimeFormat(undefined, {
    hour: "numeric",
    minute: "2-digit",
  }).format(new Date(date * 1000))
}

export function MessageBubble({
  message,
  style,
  onOpenMessage,
  onOpenReplyThread,
  onResendMessage,
  peer,
  currentUserId,
}: {
  message: ChatMessageRow
  style: InlineMessageStyle
  onOpenMessage: (messageId: MessageID) => void
  onOpenReplyThread: (chatId: ChatID) => void
  onResendMessage: (messageId: MessageID) => void
  peer: InlinePeerRoute
  currentUserId: UserID
}) {
  return (
    <div
      data-inline-message-style={style}
      {...stylex.props(
        styles.bubble,
        style === "minimal"
          ? styles.minimal
          : message.out
            ? styles.outgoing
            : styles.incoming,
      )}
    >
      {message.forwardHeader ? (
        <ForwardHeaderView
          forward={message.forwardHeader}
          currentPeer={peer}
          onOpenMessage={onOpenMessage}
          currentUserId={currentUserId}
        />
      ) : null}
      {message.embeddedReply ? (
        <EmbeddedMessageView
          reply={message.embeddedReply}
          outgoing={message.out}
          onOpen={onOpenMessage}
        />
      ) : null}
      <MessageContentView presentation={message.presentation} />
      {message.reactions ? (
        <MessageReactionsView
          reactions={message.reactions}
          messageId={message.messageId}
          chatId={message.chatId}
          peer={peer}
          currentUserId={currentUserId}
          outgoing={message.out}
        />
      ) : null}
      {message.replyThreadSummary ? (
        <ReplyThreadSummaryView
          summary={message.replyThreadSummary}
          onOpen={onOpenReplyThread}
        />
      ) : null}
      <span {...stylex.props(styles.meta)}>
        <span {...stylex.props(styles.time)}>{messageTime(message.date)}</span>
        {message.out && message.status === MessageSendingStatus.Sending ? (
          <span aria-label="Sending" {...stylex.props(styles.sending)} />
        ) : null}
        {message.out && message.status === MessageSendingStatus.Failed ? (
          <button
            type="button"
            aria-label="Resend message"
            title="Resend"
            onClick={() => onResendMessage(message.messageId)}
            {...stylex.props(styles.failed)}
          >
            !
          </button>
        ) : null}
      </span>
    </div>
  )
}

const styles = stylex.create({
  bubble: {
    maxWidth: metrics.messageMaxWidth,
    minHeight: 28,
    display: "flex",
    flexDirection: "column",
    alignItems: "stretch",
    gap: 3,
    paddingBlock: 6,
    paddingInline: 11,
    borderRadius: metrics.messageBubbleRadius,
    fontSize: 13,
    lineHeight: 1.25,
  },
  outgoing: {
    backgroundColor: colors.outgoingBubble,
    color: colors.outgoingText,
  },
  incoming: {
    backgroundColor: colors.incomingBubble,
    color: colors.textPrimary,
  },
  minimal: {
    width: "fit-content",
    maxWidth: "100%",
    minHeight: 20,
    gap: 2,
    padding: 0,
    borderRadius: 0,
    backgroundColor: "transparent",
    color: colors.textPrimary,
  },
  meta: {
    minHeight: 11,
    display: "flex",
    alignItems: "center",
    alignSelf: "flex-end",
    gap: 4,
  },
  time: {
    marginBottom: -1,
    opacity: 0.62,
    fontSize: 9,
    lineHeight: 1.2,
    whiteSpace: "nowrap",
  },
  sending: {
    width: 7,
    height: 7,
    marginBottom: 1,
    borderWidth: 1,
    borderStyle: "solid",
    borderColor: "currentColor",
    borderRadius: "50%",
    opacity: 0.65,
  },
  failed: {
    width: 13,
    height: 13,
    display: "grid",
    placeItems: "center",
    marginBottom: -2,
    padding: 0,
    borderWidth: 0,
    borderRadius: "50%",
    backgroundColor: colors.destructive,
    color: "#fff",
    fontSize: 9,
    fontWeight: 700,
    lineHeight: 1,
    cursor: "pointer",
  },
})
