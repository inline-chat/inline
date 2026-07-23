import { DbObjectKind, type User } from "@inline/client"
import * as stylex from "@stylexjs/stylex"
import { useInlineObject } from "~/inline/data/react"
import { Icon } from "~/ui/Icon"
import { colors } from "../styles/tokens.stylex"
import type { ChatMessageRow } from "./ChatRowListModel"

const replyPreview = (message: ChatMessageRow) =>
  message.presentation.text?.replace(/\s+/g, " ").trim() ||
  message.presentation.media?.label ||
  message.presentation.service ||
  message.presentation.fallback ||
  "Message"

export function ComposeReplyTargetView({
  message,
  onCancel,
}: {
  message: ChatMessageRow
  onCancel: () => void
}) {
  const user = useInlineObject<DbObjectKind.User, User>(
    DbObjectKind.User,
    message.fromId,
  )
  const sender = message.out
    ? "You"
    : [user?.firstName, user?.lastName].filter(Boolean).join(" ") ||
      user?.username ||
      "Message"

  return (
    <div {...stylex.props(styles.root)}>
      <span aria-hidden="true" {...stylex.props(styles.indicator)} />
      <span {...stylex.props(styles.content)}>
        <span {...stylex.props(styles.sender)}>Reply to {sender}</span>
        <span {...stylex.props(styles.preview)}>{replyPreview(message)}</span>
      </span>
      <button
        type="button"
        aria-label="Cancel reply"
        title="Cancel reply"
        onClick={onCancel}
        {...stylex.props(styles.cancel)}
      >
        <Icon name="xmark" size={12} />
      </button>
    </div>
  )
}

const styles = stylex.create({
  root: {
    minWidth: 0,
    width: "100%",
    height: 38,
    display: "flex",
    alignItems: "center",
    gap: 8,
    paddingInline: 2,
    borderBottomWidth: 1,
    borderBottomStyle: "solid",
    borderBottomColor: colors.separator,
  },
  indicator: {
    width: 2,
    height: 24,
    flexShrink: 0,
    borderRadius: 2,
    backgroundColor: colors.accent,
  },
  content: {
    minWidth: 0,
    display: "flex",
    flex: 1,
    flexDirection: "column",
    gap: 1,
  },
  sender: {
    color: colors.accent,
    fontSize: 10,
    fontWeight: 600,
  },
  preview: {
    overflow: "hidden",
    color: colors.textSecondary,
    fontSize: 11,
    textOverflow: "ellipsis",
    whiteSpace: "nowrap",
  },
  cancel: {
    width: 24,
    height: 24,
    display: "grid",
    placeItems: "center",
    flexShrink: 0,
    padding: 0,
    borderRadius: 6,
    color: colors.textSecondary,
    backgroundColor: {
      default: "transparent",
      ":hover": colors.hovered,
    },
  },
})
