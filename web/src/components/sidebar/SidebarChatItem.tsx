import * as stylex from "@stylexjs/stylex"
import { DbObjectKind, type Dialog, useObject, useObjectRef } from "@inline/client"

type SidebarChatItemProps = {
  dialog: Dialog
}

const getDisplayName = (firstName?: string, lastName?: string, username?: string) => {
  if (firstName || lastName) {
    return [firstName, lastName].filter(Boolean).join(" ")
  }
  if (username) return username
  return "Unknown"
}

export const SidebarChatItem = ({ dialog }: SidebarChatItemProps) => {
  const chatRef = useObjectRef(DbObjectKind.Chat, dialog.chatId)
  const chat = useObject(chatRef)
  const userRef = useObjectRef(DbObjectKind.User, dialog.peerUserId)
  const user = useObject(userRef)
  const isDm = Boolean(dialog.peerUserId)

  const title = isDm
    ? getDisplayName(user?.firstName, user?.lastName, user?.username)
    : chat?.title ?? "Thread"

  const badge = isDm ? "DM" : "Thread"
  const emoji = !isDm ? chat?.emoji : undefined

  return (
    <div {...stylex.props(styles.wrapper)}>
      <div {...stylex.props(styles.avatar)}>{emoji ?? (isDm ? "👤" : "💬")}</div>
      <div {...stylex.props(styles.content)}>
        <div {...stylex.props(styles.titleRow)}>
          <div {...stylex.props(styles.title)}>{title}</div>
          <div {...stylex.props(styles.badge)}>{badge}</div>
        </div>
      </div>
    </div>
  )
}

const styles = stylex.create({
  wrapper: {
    height: 48,
    width: "100%",
    position: "relative",
    display: "flex",
    alignItems: "center",
    paddingLeft: 10,
    paddingRight: 10,
    gap: 10,
  },
  avatar: {
    height: 30,
    width: 30,
    borderRadius: 8,
    backgroundColor: "rgba(255,255,255,0.75)",
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
    fontSize: 14,
  },
  content: {
    flexGrow: 1,
    minWidth: 0,
  },
  titleRow: {
    display: "flex",
    alignItems: "center",
    gap: 8,
  },
  title: {
    fontSize: 13,
    fontWeight: 600,
    color: "rgba(20,20,20,0.9)",
    overflow: "hidden",
    textOverflow: "ellipsis",
    whiteSpace: "nowrap",
    flexGrow: 1,
  },
  badge: {
    fontSize: 10,
    textTransform: "uppercase",
    letterSpacing: 0.6,
    color: "rgba(20,20,20,0.45)",
  },
})
