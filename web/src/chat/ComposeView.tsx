import {
  DbObjectKind,
  sendMessage,
  useInlineClient,
  type User,
} from "@inline/client"
import type { ChatID } from "@inline/ids"
import * as stylex from "@stylexjs/stylex"
import { useEffect, useMemo, useRef, useState, type FormEvent } from "react"
import { inputPeer, type InlinePeerRoute } from "~/inline/data/peer"
import { useInlineQuery } from "~/inline/data/react"
import { colors, metrics } from "../styles/tokens.stylex"
import { Icon } from "~/ui/Icon"
import { useMessageDraftText } from "./useMessageDraftText"
import { waitForMessageSendAcceptance } from "./MessageSendAcceptance"
import {
  InlineComposeEditor,
  type InlineComposeEditorHandle,
} from "./compose/InlineComposeEditor"
import type { InlineComposeDocument } from "./compose/InlineComposeDocument"
import type { ChatMessageRow } from "./ChatRowListModel"
import { ComposeReplyTargetView } from "./ComposeReplyTargetView"

const allUsers = () => true

export function ComposeView({
  peer,
  chatId,
  recipientName,
  replyTarget,
  onCancelReply,
  onReplyAccepted,
}: {
  peer: InlinePeerRoute
  chatId: ChatID
  recipientName?: string
  replyTarget?: ChatMessageRow
  onCancelReply?: () => void
  onReplyAccepted?: (messageId: ChatMessageRow["messageId"]) => void
}) {
  const { db, realtime } = useInlineClient()
  const draft = useMessageDraftText(peer)
  const { text } = draft
  const [error, setError] = useState<string>()
  const [accepting, setAccepting] = useState(false)
  const acceptingRef = useRef(false)
  const editor = useRef<InlineComposeEditorHandle>(null)
  const users = useInlineQuery<DbObjectKind.User, User>(
    `compose-mentions:${chatId}`,
    DbObjectKind.User,
    allUsers,
  )
  const mentionItems = useMemo(
    () =>
      users.flatMap((user) => {
        const name = [user.firstName, user.lastName]
          .filter(Boolean)
          .join(" ") || user.username
        return name ? [{ userId: user.id, name }] : []
      }),
    [users],
  )

  useEffect(() => {
    if (replyTarget) editor.current?.focus()
  }, [replyTarget?.messageId])

  const submit = async (
    content: InlineComposeDocument,
    event?: FormEvent,
  ) => {
    event?.preventDefault()
    if (acceptingRef.current) return
    if (!content.text.trim()) return
    const message = content.text
    const replyToMsgId = replyTarget?.messageId
    acceptingRef.current = true
    setAccepting(true)
    setError(undefined)
    const submittedRevision = draft.currentRevision()
    const transaction = sendMessage({
      chatId,
      peerId: inputPeer(peer),
      text: message,
      entities: content.entities,
      replyToMsgId,
    })
    const temporaryMessageId =
      transaction.context.temporaryMessageId
    if (temporaryMessageId == null) {
      acceptingRef.current = false
      setAccepting(false)
      setError("Message was not accepted.")
      return
    }
    const send = realtime.mutate(transaction)
    void send.catch(() => undefined)
    try {
      await waitForMessageSendAcceptance(
        db,
        chatId,
        temporaryMessageId,
        send,
      )
    } catch (cause) {
      acceptingRef.current = false
      setAccepting(false)
      setError(
        cause instanceof Error
          ? cause.message
          : "Message was not accepted.",
      )
      return
    }
    const cleared = await draft
      .clearIfUnchanged(submittedRevision)
      .catch((cause) => {
        console.error("Could not clear Inline message draft", cause)
        return false
      })
    if (cleared) editor.current?.clear()
    if (replyToMsgId != null) onReplyAccepted?.(replyToMsgId)
    acceptingRef.current = false
    setAccepting(false)
    try {
      await send
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "Message was not sent.")
    }
  }

  return (
    <div {...stylex.props(styles.outer)}>
      <form
        onSubmit={(event) =>
          void submit(
            { text, entities: draft.entities },
            event,
          )
        }
        {...stylex.props(styles.form)}
      >
        {replyTarget && onCancelReply ? (
          <ComposeReplyTargetView
            message={replyTarget}
            onCancel={onCancelReply}
          />
        ) : null}
        <div {...stylex.props(styles.editorRow)}>
          <div {...stylex.props(styles.editorFrame)}>
            <InlineComposeEditor
              key={String(chatId)}
              ref={editor}
              value={{ text, entities: draft.entities }}
              placeholder={recipientName ? `Message ${recipientName}` : "Message"}
              mentionItems={mentionItems}
              onChange={(content) =>
                draft.setContent(content.text, content.entities)
              }
              onSubmit={(content) => void submit(content)}
            />
          </div>
          <button
            type="submit"
            aria-label="Send"
            disabled={accepting || !text.trim()}
            {...stylex.props(styles.send)}
          >
            <Icon name="arrowUp" size={16} />
          </button>
        </div>
      </form>
      {error ? (
        <span role="alert" title={error} {...stylex.props(styles.error)}>
          Not sent
        </span>
      ) : null}
    </div>
  )
}

const styles = stylex.create({
  outer: {
    paddingInline: metrics.composeOuterInset,
    paddingBottom: 10,
    flexShrink: 0,
    backgroundColor: colors.content,
  },
  form: {
    minHeight: metrics.composeMinHeight,
    display: "flex",
    position: "relative",
    flexDirection: "column",
    padding: 5,
    paddingLeft: 10,
    borderWidth: 1,
    borderStyle: "solid",
    borderColor: colors.controlOutline,
    borderRadius: 13,
    backgroundColor: colors.control,
    boxShadow: "0 1px 3px rgba(0,0,0,.04)",
  },
  editorRow: {
    minWidth: 0,
    width: "100%",
    display: "flex",
    position: "relative",
    alignItems: "flex-end",
    gap: 5,
  },
  editorFrame: {
    minWidth: 0,
    position: "relative",
    flex: 1,
  },
  send: {
    width: metrics.composeButtonSize,
    height: metrics.composeButtonSize,
    display: "grid",
    placeItems: "center",
    flexShrink: 0,
    padding: 0,
    borderRadius: "50%",
    backgroundColor: colors.accent,
    color: "#fff",
    opacity: {
      default: 1,
      ":disabled": 0.28,
    },
  },
  error: {
    position: "absolute",
    right: 22,
    marginTop: 2,
    color: colors.destructive,
    fontSize: 9,
  },
})
