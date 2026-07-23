import {
  DbObjectKind,
  compareMessagesByWindow,
  pinMessage,
  useInlineClient,
  type Chat,
  type Dialog,
  type Message,
  type User,
} from "@inline/client"
import * as stylex from "@stylexjs/stylex"
import { useNavigate } from "@tanstack/react-router"
import { useCallback, useLayoutEffect, useMemo, useRef, useState } from "react"
import type { ChatID, MessageID } from "@inline/ids"
import type { InlinePeerRoute } from "~/inline/data/peer"
import { dialogMatchesPeer, inputPeer } from "~/inline/data/peer"
import { useInlineObject, useInlineQuery } from "~/inline/data/react"
import { useInlineMessageReferences } from "~/inline/messages/InlineMessageReferencesContext"
import {
  useFullChatProgressive,
  useInlineRuntimeState,
} from "~/inline/runtime/InlineRuntimeContext"
import { colors } from "../styles/tokens.stylex"
import { ChatToolbar } from "./ChatToolbar"
import {
  makeChatMessageRows,
  type ChatMessageRow,
} from "./ChatRowListModel"
import { ComposeView } from "./ComposeView"
import { MessageListView, type MessageListViewHandle } from "./MessageListView"
import {
  makePinnedMessageHeaderPresentation,
  PinnedMessageHeaderView,
} from "./PinnedMessageHeaderView"
import { useChatHistory } from "./useChatHistory"
import { useChatOpenPaintTrace } from "./useChatOpenPaintTrace"
import { useChatReadState } from "./useChatReadState"
import type { PreparedChatPayload } from "./ChatOpenPreloader"
import { preparedChatMatchesRoute } from "./PreparedChatRoute"
import { useInlineToast } from "~/ui/InlineToast"

export function ChatView({
  peer,
  targetMessageId,
  prepared,
  onPreparedPresentationAdopted,
}: {
  peer: InlinePeerRoute
  targetMessageId?: MessageID
  prepared?: PreparedChatPayload
  onPreparedPresentationAdopted?: () => void
}) {
  const messageList = useRef<MessageListViewHandle>(null)
  const navigate = useNavigate()
  const toast = useInlineToast()
  const { accountId, connectionState } = useInlineRuntimeState()
  const fullChatProgressive = useFullChatProgressive()
  const { db, realtime } = useInlineClient()
  const preparedPresentation = preparedChatMatchesRoute(
    prepared,
    accountId,
    peer,
  )
    ? prepared
    : undefined
  const handledTarget = useRef<MessageID | undefined>(undefined)
  const requestedTarget = useRef<MessageID | undefined>(undefined)
  const [replyState, setReplyState] = useState<{
    chatId: ChatID
    message: ChatMessageRow
  }>()
  const dialogPredicate = useCallback(
    (dialog: Dialog) => dialogMatchesPeer(dialog, peer),
    [peer.peerId, peer.peerKind],
  )
  const dialogs = useInlineQuery<DbObjectKind.Dialog, Dialog>(
    `peer:${peer.peerKind}:${peer.peerId}`,
    DbObjectKind.Dialog,
    dialogPredicate,
  )
  const preparedDialog = useInlineObject<
    DbObjectKind.Dialog,
    Dialog
  >(DbObjectKind.Dialog, preparedPresentation?.dialogId)
  const dialog = preparedDialog ?? dialogs.at(0)
  const chatId = preparedPresentation?.chatId ?? dialog?.chatId
  const chat = useInlineObject<DbObjectKind.Chat, Chat>(
    DbObjectKind.Chat,
    chatId,
  )
  const pinnedMessageId = chat
    ? chat.pinnedMessageIds?.at(0)
    : preparedPresentation?.pinnedMessageId

  useLayoutEffect(() => {
    if (chatId == null) return
    const release = fullChatProgressive.activateChat(chatId)
    onPreparedPresentationAdopted?.()
    return release
  }, [
    chatId,
    fullChatProgressive,
    onPreparedPresentationAdopted,
  ])
  const peerUserId = peer.peerKind === "user" ? peer.peerId : dialog?.peerUserId
  const user = useInlineObject<DbObjectKind.User, User>(DbObjectKind.User, peerUserId)
  const messagePredicate = useCallback(
    (message: Message) =>
      chatId != null &&
      message.chatId === chatId &&
      db.isMessageInHistoryWindow(chatId, message.id),
    [chatId, db],
  )
  const cachedMessages = useInlineQuery<DbObjectKind.Message, Message>(
    `chat:${chatId ?? "pending"}`,
    DbObjectKind.Message,
    messagePredicate,
  )
  const preparedMessages = useMemo(() => {
    return preparedPresentation?.messagesInitialState ?? []
  }, [preparedPresentation])
  const messages = useMemo(
    () => {
      const messagesById = new Map<Message["id"], Message>()
      for (const message of preparedMessages) {
        messagesById.set(message.id, message)
      }
      for (const message of cachedMessages) {
        messagesById.set(message.id, message)
      }
      return [...messagesById.values()].sort(compareMessagesByWindow)
    },
    [cachedMessages, preparedMessages],
  )
  const referenceMessageIds = useMemo(
    () =>
      [
        ...messages.flatMap((message) =>
          message.replyToMsgId ? [message.replyToMsgId] : [],
        ),
        ...(pinnedMessageId ? [pinnedMessageId] : []),
      ],
    [messages, pinnedMessageId],
  )
  const referencedMessages = useInlineMessageReferences(
    peer,
    chatId,
    referenceMessageIds,
    connectionState,
  )
  const pinnedMessagePresentation = useMemo(
    () =>
      makePinnedMessageHeaderPresentation(
        pinnedMessageId
          ? referencedMessages.get(pinnedMessageId)
          : undefined,
      ),
    [pinnedMessageId, referencedMessages],
  )
  const messageRows = useMemo(
    () => makeChatMessageRows(messages, referencedMessages),
    [messages, referencedMessages],
  )
  const replyTarget =
    replyState && replyState.chatId === chatId
      ? replyState.message
      : undefined
  const history = useChatHistory(
    peer,
    chatId,
    preparedPresentation?.chatId,
    dialog,
    preparedPresentation?.needsHistoryRefresh ?? false,
  )
  const hasNewer =
    chat?.lastMsgId != null &&
    !messages.some(
      (message) => message.messageId === chat.lastMsgId,
    )
  const updateVisibleRange = useCallback(
    (
      firstVisibleMessageId: MessageID,
      lastVisibleMessageId: MessageID,
    ) => {
      if (chatId == null) return
      fullChatProgressive.updateVisibleRange(
        chatId,
        firstVisibleMessageId,
        lastVisibleMessageId,
      )
    },
    [chatId, fullChatProgressive],
  )
  const unreadBoundary = useRef<{
    chatId: string
    messageId?: MessageID
  } | undefined>(undefined)
  if (
    dialog &&
    unreadBoundary.current?.chatId !== dialog.chatId
  ) {
    unreadBoundary.current = {
      chatId: dialog.chatId,
      messageId:
        (dialog.unreadCount ?? 0) > 0
          ? dialog.readMaxId
          : undefined,
    }
  }
  const readState = useChatReadState({
    peer,
    dialog,
    latestMessageId: messageRows.at(-1)?.messageId,
  })
  const recipientName = user?.firstName
  const traceFirstMessageListLayout = useChatOpenPaintTrace(
    preparedPresentation?.performanceTraceId,
    messageRows.length,
  )
  const onFirstMessageListLayout = useCallback(() => {
    traceFirstMessageListLayout()
  }, [traceFirstMessageListLayout])

  useLayoutEffect(() => {
    if (!targetMessageId || handledTarget.current === targetMessageId) return
    if (messageList.current?.scrollToMessage(targetMessageId)) {
      handledTarget.current = targetMessageId
      return
    }
    if (requestedTarget.current === targetMessageId) return
    requestedTarget.current = targetMessageId
    void history.loadAround(targetMessageId).then((found) => {
      if (!found && requestedTarget.current === targetMessageId) {
        handledTarget.current = targetMessageId
      }
    })
  }, [history.loadAround, messageRows, targetMessageId])

  const openEmbeddedMessage = useCallback(
    (messageId: MessageID) => {
      if (messageList.current?.scrollToMessage(messageId)) return
      void history.loadAround(messageId).then((found) => {
        if (!found) return
        requestAnimationFrame(() => {
          messageList.current?.scrollToMessage(messageId)
        })
      })
    },
    [history.loadAround],
  )

  const openReplyThread = useCallback(
    (chatId: ChatID) => {
      void navigate({
        to: "/chat/$peerKind/$peerId",
        params: { peerKind: "chat", peerId: chatId },
      })
    },
    [navigate],
  )
  const unpinMessage = useCallback(
    async (messageId: MessageID) => {
      await realtime.mutateAccepted(
        pinMessage({
          peerId: inputPeer(peer),
          messageId,
          unpin: true,
        }),
      )
    },
    [peer.peerId, peer.peerKind, realtime],
  )

  const resendMessage = useCallback(
    (messageId: MessageID) => {
      if (chatId == null) return
      void realtime
        .resendMessage(chatId, messageId)
        .catch((cause: unknown) => {
          console.error("Could not resend Inline message", cause)
          toast.show("Could not resend message", "error")
        })
    },
    [chatId, realtime, toast],
  )
  const replyToMessage = useCallback(
    (message: ChatMessageRow) => {
      if (chatId == null) return
      setReplyState({ chatId, message })
    },
    [chatId],
  )
  const togglePinnedMessage = useCallback(
    (message: ChatMessageRow) => {
      const unpin = Boolean(
        chat?.pinnedMessageIds?.includes(message.messageId),
      )
      const transaction = pinMessage({
        peerId: inputPeer(peer),
        messageId: message.messageId,
        unpin,
      })
      const operation = unpin
        ? realtime.mutateAccepted(transaction)
        : realtime.mutate(transaction)
      void operation
        .catch((cause: unknown) => {
          console.error("Could not update Inline pinned message", cause)
          toast.show("Could not update pinned message", "error")
        })
    },
    [chat?.pinnedMessageIds, peer.peerId, peer.peerKind, realtime, toast],
  )
  const cancelReply = useCallback(() => setReplyState(undefined), [])
  const clearAcceptedReply = useCallback((messageId: MessageID) => {
    setReplyState((current) =>
      current?.message.messageId === messageId ? undefined : current,
    )
  }, [])

  return (
    <section
      data-inline-chat-prepared={preparedPresentation ? "true" : "false"}
      data-inline-chat-message-count={messageRows.length}
      data-inline-chat-active={readState.active ? "true" : "false"}
      data-inline-core-connection-state={connectionState}
      data-inline-chat-at-bottom={readState.atBottom ? "true" : "false"}
      data-inline-chat-needs-read={readState.needsRead ? "true" : "false"}
      data-inline-chat-latest-message-id={readState.latestMessageId}
      {...stylex.props(styles.root)}
    >
      <ChatToolbar
        peer={peer}
        peerUserId={peerUserId}
        chatId={chatId}
        dialogId={dialog?.id}
      />
      {pinnedMessageId ? (
        <PinnedMessageHeaderView
          messageId={pinnedMessageId}
          presentation={pinnedMessagePresentation}
          onOpen={openEmbeddedMessage}
          onUnpin={unpinMessage}
        />
      ) : null}
      <div {...stylex.props(styles.messages)}>
        <MessageListView
          ref={messageList}
          key={chatId ?? `${peer.peerKind}:${peer.peerId}`}
          rows={messageRows}
          loading={history.initialLoading}
          loadingOlder={history.loadingOlder}
          loadingNewer={history.loadingNewer}
          hasOlder={history.hasOlder}
          hasNewer={hasNewer}
          showParticipants={peer.peerKind === "chat"}
          scrollStateKey={
            `${accountId}:${chatId ?? `${peer.peerKind}:${peer.peerId}`}`
          }
          onLoadOlder={(before) =>
            void history.loadOlder(before)
          }
          onLoadNewer={(after) =>
            void history.loadNewer(after)
          }
          onVisibleRangeChange={updateVisibleRange}
          onFirstLayout={onFirstMessageListLayout}
          expectedInitialRowCount={
            preparedPresentation?.preparedMessageCount
          }
          onBottomStateChange={readState.onBottomStateChange}
          unreadAfterMessageId={unreadBoundary.current?.messageId}
          onOpenMessage={openEmbeddedMessage}
          onOpenReplyThread={openReplyThread}
          onResendMessage={resendMessage}
          onReplyMessage={replyToMessage}
          onTogglePinMessage={togglePinnedMessage}
          pinnedMessageIds={chat?.pinnedMessageIds?.map(String)}
          peer={peer}
          currentUserId={accountId}
        />
      </div>
      {history.error && messages.length === 0 ? (
        <p role="alert" {...stylex.props(styles.error)}>
          {history.error}
        </p>
      ) : null}
      {chatId != null ? (
        <ComposeView
          key={chatId}
          peer={peer}
          chatId={chatId}
          recipientName={recipientName}
          replyTarget={replyTarget}
          onCancelReply={cancelReply}
          onReplyAccepted={clearAcceptedReply}
        />
      ) : null}
    </section>
  )
}

const styles = stylex.create({
  root: {
    width: "100%",
    height: "100%",
    display: "flex",
    flexDirection: "column",
    position: "relative",
    overflow: "hidden",
    backgroundColor: colors.content,
  },
  messages: {
    minHeight: 0,
    flex: 1,
    overflow: "hidden",
  },
  error: {
    margin: "0 18px 8px",
    color: colors.destructive,
    fontSize: 11,
    textAlign: "center",
  },
})
