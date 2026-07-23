import {
  DbObjectKind,
  type Chat,
  type User,
} from "@inline/client"
import * as stylex from "@stylexjs/stylex"
import type { ChatID, UserID } from "@inline/ids"
import { useInlineObject } from "~/inline/data/react"
import { UserAvatar } from "~/ui/Avatar"
import { colors } from "../styles/tokens.stylex"
import type { ChatMessageReplyThreadSummary } from "./ChatRowListModel"

function ReplyAvatar({ userId }: { userId: UserID }) {
  const user = useInlineObject<DbObjectKind.User, User>(
    DbObjectKind.User,
    userId,
  )
  return <UserAvatar user={user} size={16} />
}

export function ReplyThreadSummaryView({
  summary,
  onOpen,
}: {
  summary: ChatMessageReplyThreadSummary
  onOpen: (chatId: ChatID) => void
}) {
  const chat = useInlineObject<DbObjectKind.Chat, Chat>(
    DbObjectKind.Chat,
    summary.chatId,
  )
  const title = chat?.title?.trim()
  const label = `${summary.replyCount} ${
    summary.replyCount === 1 ? "reply" : "replies"
  }`

  return (
    <button
      type="button"
      onClick={() => onOpen(summary.chatId)}
      {...stylex.props(styles.root)}
    >
      {title ? <span {...stylex.props(styles.title)}>{title}</span> : null}
      <span {...stylex.props(styles.line)}>
        <span {...stylex.props(styles.avatars)}>
          {summary.recentReplierUserIds.slice(0, 3).map((userId) => (
            <span key={userId} {...stylex.props(styles.avatar)}>
              <ReplyAvatar userId={userId} />
            </span>
          ))}
        </span>
        <span {...stylex.props(styles.label)}>{label}</span>
        {summary.hasUnread ? (
          <span aria-label="Unread replies" {...stylex.props(styles.unread)} />
        ) : null}
      </span>
    </button>
  )
}

const styles = stylex.create({
  root: {
    minWidth: 200,
    maxWidth: 260,
    minHeight: 30,
    display: "flex",
    flexDirection: "column",
    justifyContent: "center",
    gap: 2,
    marginTop: 2,
    padding: 0,
    borderWidth: 0,
    backgroundColor: "transparent",
    color: "inherit",
    font: "inherit",
    textAlign: "start",
    cursor: "pointer",
  },
  title: {
    overflow: "hidden",
    fontSize: 10,
    fontWeight: 600,
    textOverflow: "ellipsis",
    whiteSpace: "nowrap",
  },
  line: {
    minHeight: 20,
    display: "flex",
    alignItems: "center",
    gap: 6,
  },
  avatars: {
    display: "flex",
    paddingInlineStart: 2,
  },
  avatar: {
    display: "inline-flex",
    marginInlineStart: -2,
    borderWidth: 1,
    borderStyle: "solid",
    borderColor: "currentColor",
    borderRadius: "50%",
  },
  label: {
    fontSize: 10,
    fontWeight: 500,
    opacity: 0.78,
  },
  unread: {
    width: 6,
    height: 6,
    borderRadius: "50%",
    backgroundColor: colors.unread,
  },
})
