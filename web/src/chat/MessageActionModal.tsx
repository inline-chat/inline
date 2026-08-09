import {
  DbObjectKind,
  MessageSendingStatus,
  addReaction,
  deleteMessages,
  editMessage,
  forwardMessages,
  type Chat,
  type Dialog,
  type User,
  useInlineClient,
} from "@inline/client"
import type { MessageEntities } from "@inline-chat/protocol/core"
import * as stylex from "@stylexjs/stylex"
import { useEffect, useMemo, useRef, useState } from "react"
import { dialogPeerRoute, inputPeer, type InlinePeerRoute } from "~/inline/data/peer"
import { useInlineObject, useInlineQuery } from "~/inline/data/react"
import { useInlineChatTitle } from "~/inline/data/useInlineChatTitle"
import { inlineLog } from "~/inline/logging/InlineLogging"
import { ThreadAvatar, UserAvatar } from "~/ui/Avatar"
import { InlineButton } from "~/ui/InlineButton"
import { InlineModal } from "~/ui/InlineModal"
import { InlineTextInput } from "~/ui/InlineTextInput"
import { useInlineToast } from "~/ui/InlineToast"
import { colors } from "../styles/tokens.stylex"
import type { ChatMessageRow } from "./ChatRowListModel"
import { transformEditedMessageEntities } from "./MessageEditEntities"

const log = inlineLog.withScope("UI.MessageActionModal")
const allDialogs = () => true
const allChats = () => true
const commonReactions = ["👍", "❤️", "😂", "🎉", "😮", "😢", "🙏", "👀"]

type MessageEditDocument = {
  text: string
  entities?: MessageEntities
}

export type MessageActionModalState = {
  kind: "edit" | "delete" | "forward" | "reaction"
  message: ChatMessageRow
}

function ForwardDestinationRow({
  dialog,
  search,
  onSelect,
}: {
  dialog: Dialog
  search: string
  onSelect: (dialog: Dialog) => void
}) {
  const chat = useInlineObject<DbObjectKind.Chat, Chat>(
    DbObjectKind.Chat,
    dialog.chatId,
  )
  const user = useInlineObject<DbObjectKind.User, User>(
    DbObjectKind.User,
    dialog.peerUserId,
  )
  const chatTitle = useInlineChatTitle(chat)
  const title = user
    ? [user.firstName, user.lastName].filter(Boolean).join(" ") ||
      user.username
    : chatTitle
  if (
    search &&
    !(title ?? "").toLocaleLowerCase().includes(search.toLocaleLowerCase())
  ) {
    return null
  }
  return (
    <button
      type="button"
      data-forward-title={(title ?? "").toLocaleLowerCase()}
      onClick={() => onSelect(dialog)}
      {...stylex.props(styles.destination)}
    >
      {user ? (
        <UserAvatar user={user} size={30} />
      ) : (
        <ThreadAvatar emoji={chat?.emoji} size={30} />
      )}
      <span {...stylex.props(styles.destinationTitle)}>
        {title || "Untitled chat"}
      </span>
    </button>
  )
}

export function MessageActionModal({
  state,
  peer,
  onClose,
}: {
  state?: MessageActionModalState
  peer: InlinePeerRoute
  onClose: () => void
}) {
  const { realtime } = useInlineClient()
  const toast = useInlineToast()
  const [editDocument, setEditDocument] = useState<MessageEditDocument>({
    text: "",
  })
  const [search, setSearch] = useState("")
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string>()
  const dismissed = useRef(false)
  const stateVersion = useRef(0)
  const dialogs = useInlineQuery<DbObjectKind.Dialog, Dialog>(
    "message-forward-dialogs",
    DbObjectKind.Dialog,
    allDialogs,
  )
  const chats = useInlineQuery<DbObjectKind.Chat, Chat>(
    "message-forward-chats",
    DbObjectKind.Chat,
    allChats,
  )
  const orderedDialogs = useMemo(() => {
    const chatsById = new Map(chats.map((chat) => [chat.id, chat]))
    return dialogs
      .filter((dialog) => !dialog.archived && !dialog.chatListHidden)
      .sort((left, right) =>
        (chatsById.get(right.chatId)?.date ?? 0) -
          (chatsById.get(left.chatId)?.date ?? 0),
      )
  }, [chats, dialogs])

  useEffect(() => {
    stateVersion.current += 1
    if (state) dismissed.current = false
    setEditDocument({
      text: state?.message.presentation.text ?? "",
      entities: state?.message.presentation.entities,
    })
    setSearch("")
    setError(undefined)
    setBusy(false)
  }, [state?.kind, state?.message.id])

  if (!state) return null
  const { message, kind } = state
  const editText = editDocument.text
  const requestClose = () => {
    if (dismissed.current) return
    dismissed.current = true
    onClose()
  }
  const run = async (
    operation: () => Promise<unknown>,
    success?: string,
    requiresConnection = true,
  ) => {
    if (busy) return
    if (requiresConnection && realtime.connectionState !== "connected") {
      setError("Connect to Inline before updating this message.")
      return
    }
    const startedVersion = stateVersion.current
    setBusy(true)
    setError(undefined)
    try {
      await operation()
      if (success) toast.show(success)
      if (stateVersion.current === startedVersion) requestClose()
    } catch (cause) {
      log.warn("ui.message.action.failed", { action: kind, error: cause })
      if (
        dismissed.current ||
        stateVersion.current !== startedVersion
      ) return
      setError(cause instanceof Error ? cause.message : "Could not update message")
      setBusy(false)
    }
  }
  const cancelLocal =
    message.status === MessageSendingStatus.Sending ||
    message.status === MessageSendingStatus.Failed
  const title = {
    edit: "Edit Message",
    delete: cancelLocal ? "Cancel Send" : "Delete Message",
    forward: "Forward Message",
    reaction: "Add Reaction",
  }[kind]

  const footer = kind === "edit" || kind === "delete" ? (
    <>
      <InlineButton onClick={requestClose}>Cancel</InlineButton>
      <InlineButton
        variant={kind === "delete" ? "destructive" : "primary"}
        disabled={busy || (kind === "edit" && !editText.trim())}
        onClick={() => {
          if (kind === "edit") {
            void run(
              () => realtime.mutate(editMessage({
                chatId: message.chatId,
                messageId: message.messageId,
                peerId: inputPeer(peer),
                text: editText,
                entities: editDocument.entities,
              })),
              "Message updated",
            )
            return
          }
          void run(async () => {
            if (cancelLocal) {
              const cancelled = await realtime.cancelPendingMessage?.(
                message.chatId,
                message.messageId,
              )
              if (!cancelled) {
                throw new Error("This message has already started sending")
              }
              return
            }
            await realtime.mutate(deleteMessages({
              chatId: message.chatId,
              messageIds: [message.messageId],
              peerId: inputPeer(peer),
            }))
          }, cancelLocal ? "Send cancelled" : "Message deleted", !cancelLocal)
        }}
      >
        {busy ? "Working…" : kind === "edit" ? "Save" : cancelLocal ? "Cancel Send" : "Delete"}
      </InlineButton>
    </>
  ) : undefined

  return (
    <InlineModal
      open
      onOpenChange={(open) => {
        if (!open) requestClose()
      }}
      title={title}
      description={
        kind === "delete" && !cancelLocal
          ? "This removes the message for everyone who can see it."
          : undefined
      }
      footer={footer}
    >
      {kind === "edit" ? (
        <textarea
          autoFocus
          value={editText}
          maxLength={100_000}
          onChange={(event) => {
            const nextText = event.currentTarget.value
            const originalText = message.presentation.text ?? ""
            setEditDocument((current) => ({
              text: nextText,
              entities: nextText === originalText
                ? message.presentation.entities
                : transformEditedMessageEntities(
                    current.text,
                    nextText,
                    current.entities,
                  ),
            }))
          }}
          {...stylex.props(styles.editor)}
        />
      ) : null}
      {kind === "delete" ? (
        <p {...stylex.props(styles.confirmation)}>
          {cancelLocal
            ? "Remove this unsent message and its durable retry?"
            : "Delete this message? This action cannot be undone."}
        </p>
      ) : null}
      {kind === "reaction" ? (
        <div aria-label="Choose reaction" {...stylex.props(styles.reactions)}>
          {commonReactions.map((emoji) => (
            <button
              key={emoji}
              type="button"
              aria-label={`React with ${emoji}`}
              disabled={busy}
              onClick={() =>
                void run(() => realtime.mutate(addReaction({
                  emoji,
                  chatId: message.chatId,
                  messageId: message.messageId,
                  peerId: inputPeer(peer),
                })))
              }
              {...stylex.props(styles.reaction)}
            >
              {emoji}
            </button>
          ))}
        </div>
      ) : null}
      {kind === "forward" ? (
        <div {...stylex.props(styles.forward)}>
          <InlineTextInput
            autoFocus
            value={search}
            placeholder="Search chats"
            aria-label="Search forward destinations"
            onChange={(event) => setSearch(event.currentTarget.value)}
          />
          <div {...stylex.props(styles.destinations)}>
            {orderedDialogs.map((dialog) => (
              <ForwardDestinationRow
                key={dialog.id}
                dialog={dialog}
                search={search}
                onSelect={(destination) =>
                  void run(
                    () => realtime.mutate(forwardMessages({
                      fromChatId: message.chatId,
                      fromPeerId: inputPeer(peer),
                      toPeerId: inputPeer(dialogPeerRoute(destination)),
                      messageIds: [message.messageId],
                      shareForwardHeader: true,
                    })),
                    "Message forwarded",
                  )
                }
              />
            ))}
          </div>
        </div>
      ) : null}
      {error ? <p role="alert" {...stylex.props(styles.error)}>{error}</p> : null}
    </InlineModal>
  )
}

const styles = stylex.create({
  editor: {
    width: "100%",
    minHeight: 110,
    resize: "vertical",
    padding: 10,
    borderWidth: 1,
    borderStyle: "solid",
    borderColor: colors.controlOutline,
    borderRadius: 8,
    backgroundColor: colors.control,
    color: colors.textPrimary,
    font: "inherit",
    outline: "none",
    ":focus": {
      borderColor: colors.accent,
    },
  },
  confirmation: {
    margin: 0,
    color: colors.textSecondary,
    fontSize: 13,
    lineHeight: 1.4,
  },
  reactions: {
    display: "grid",
    gridTemplateColumns: "repeat(4, 1fr)",
    gap: 8,
  },
  reaction: {
    height: 48,
    borderWidth: 0,
    borderRadius: 9,
    backgroundColor: {
      default: colors.control,
      ":hover": colors.controlHover,
    },
    fontSize: 24,
    cursor: "pointer",
  },
  forward: {
    display: "flex",
    flexDirection: "column",
    gap: 10,
  },
  destinations: {
    maxHeight: 340,
    overflowY: "auto",
  },
  destination: {
    width: "100%",
    minHeight: 42,
    display: "flex",
    alignItems: "center",
    gap: 9,
    paddingBlock: 5,
    paddingInline: 7,
    borderWidth: 0,
    borderRadius: 7,
    backgroundColor: {
      default: "transparent",
      ":hover": colors.hovered,
    },
    color: colors.textPrimary,
    textAlign: "left",
    cursor: "pointer",
  },
  destinationTitle: {
    minWidth: 0,
    overflow: "hidden",
    fontSize: 13,
    textOverflow: "ellipsis",
    whiteSpace: "nowrap",
  },
  error: {
    margin: "10px 0 0",
    color: colors.destructive,
    fontSize: 11,
  },
})
