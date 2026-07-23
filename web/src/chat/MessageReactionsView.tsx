import {
  DbObjectKind,
  addReaction,
  deleteReaction,
  type User,
  useRealtimeClient,
} from "@inline/client"
import type { ChatID, MessageID, UserID } from "@inline/ids"
import * as stylex from "@stylexjs/stylex"
import { useMemo } from "react"
import { inputPeer, type InlinePeerRoute } from "~/inline/data/peer"
import { useInlineObject } from "~/inline/data/react"
import { UserAvatar } from "~/ui/Avatar"
import { colors } from "../styles/tokens.stylex"
import type { ChatMessageReactions } from "./ChatRowListModel"
import {
  resolveMessageReactionGroups,
  type MessageReactionGroup,
} from "./MessageReactions"
import { useInlineToast } from "~/ui/InlineToast"

function ReactionAvatar({ userId }: { userId: UserID }) {
  const user = useInlineObject<DbObjectKind.User, User>(
    DbObjectKind.User,
    userId,
  )
  return <UserAvatar user={user} size={20} />
}

function ReactionChip({
  group,
  outgoing,
  onToggle,
}: {
  group: MessageReactionGroup
  outgoing: boolean
  onToggle: (group: MessageReactionGroup) => void
}) {
  const count = group.reactions.length
  const label = `${group.emoji}, ${count} ${count === 1 ? "reaction" : "reactions"}${group.weReacted ? ", you reacted" : ""}`
  return (
    <button
      type="button"
      aria-label={label}
      aria-pressed={group.weReacted}
      data-pending={group.pending || undefined}
      onClick={() => onToggle(group)}
      {...stylex.props(
        styles.chip,
        outgoing ? styles.outgoingChip : styles.incomingChip,
        group.weReacted && styles.selectedChip,
        group.pending && styles.pendingChip,
      )}
    >
      <span {...stylex.props(styles.emoji)}>{group.emoji}</span>
      {count <= 3 ? (
        <span {...stylex.props(styles.avatars)}>
          {group.reactions.map((reaction) => (
            <span key={reaction.userId} {...stylex.props(styles.avatar)}>
              <ReactionAvatar userId={reaction.userId} />
            </span>
          ))}
        </span>
      ) : (
        <span {...stylex.props(styles.count)}>{count}</span>
      )}
    </button>
  )
}

export function MessageReactionsView({
  reactions,
  messageId,
  chatId,
  peer,
  currentUserId,
  outgoing,
}: {
  reactions: ChatMessageReactions
  messageId: MessageID
  chatId: ChatID
  peer: InlinePeerRoute
  currentUserId: UserID
  outgoing: boolean
}) {
  const realtime = useRealtimeClient()
  const toast = useInlineToast()
  const groups = useMemo(
    () => resolveMessageReactionGroups(reactions, currentUserId),
    [reactions, currentUserId],
  )
  if (groups.length === 0) return null

  const toggle = (group: MessageReactionGroup) => {
    const context = {
      emoji: group.emoji,
      chatId,
      messageId,
      peerId: inputPeer(peer),
    }
    const transaction = group.weReacted
      ? deleteReaction(context)
      : addReaction(context)
    void realtime.mutate(transaction).catch((cause) => {
      console.error("Could not update Inline reaction", cause)
      toast.show("Could not update reaction", "error")
    })
  }

  return (
    <span aria-label="Reactions" {...stylex.props(styles.root)}>
      {groups.map((group) => (
        <ReactionChip
          key={group.emoji}
          group={group}
          outgoing={outgoing}
          onToggle={toggle}
        />
      ))}
    </span>
  )
}

const styles = stylex.create({
  root: {
    minHeight: 26,
    display: "flex",
    flexWrap: "wrap",
    gap: 6,
    marginTop: 3,
  },
  chip: {
    height: 26,
    minWidth: 0,
    display: "inline-flex",
    alignItems: "center",
    gap: 4,
    paddingBlock: 0,
    paddingInline: 4,
    borderWidth: 0,
    borderRadius: 13,
    color: colors.accent,
    fontFamily: "inherit",
    cursor: "default",
    transitionProperty: "transform, opacity, background-color, color",
    transitionDuration: "140ms",
    ':active': {
      transform: "scale(.96)",
    },
  },
  incomingChip: {
    backgroundColor: "color-mix(in srgb, currentColor 20%, transparent)",
  },
  outgoingChip: {
    backgroundColor: "rgba(255,255,255,.20)",
    color: "#fff",
  },
  selectedChip: {
    backgroundColor: "currentColor",
    color: "light-dark(#fff, #16131d)",
  },
  pendingChip: {
    opacity: 0.72,
  },
  emoji: {
    fontSize: 14,
    lineHeight: 1,
  },
  avatars: {
    height: 20,
    display: "flex",
    paddingRight: 0,
  },
  avatar: {
    width: 16,
    height: 20,
    display: "block",
    overflow: "visible",
    ":last-child": {
      width: 20,
    },
  },
  count: {
    minWidth: 12,
    paddingRight: 2,
    textAlign: "center",
    fontSize: 12,
    lineHeight: 1,
  },
})
