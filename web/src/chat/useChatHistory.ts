import {
  getChat,
  getChatHistory,
  GetChatHistoryMode,
  messageWindowCursorKey,
  showInChatList,
  updateDialogOpen,
  type Dialog,
  type MessageWindowCursor,
  useInlineClient,
} from "@inline/client"
import type { ChatID } from "@inline/ids"
import type { MessageID } from "@inline/ids"
import { useCallback, useEffect, useRef, useState } from "react"
import { inputPeer, type InlinePeerRoute } from "~/inline/data/peer"
import { loadChatWindowAroundMessage } from "./ChatMessageWindow"

const initialLimit = 60
const olderLimit = 50
const newerLimit = 50

type InitialChatLoadOutcome = {
  hasOlder?: boolean
  error?: string
}

export function useChatHistory(
  peer: InlinePeerRoute,
  chatId?: ChatID,
  preparedChatId?: ChatID,
  dialog?: Pick<Dialog, "open" | "chatListHidden">,
  preparedNeedsHistoryRefresh = false,
) {
  const { db, realtime } = useInlineClient()
  const [initialLoading, setInitialLoading] = useState(
    chatId == null ||
      preparedChatId !== chatId ||
      preparedNeedsHistoryRefresh,
  )
  const [loadingOlder, setLoadingOlder] = useState(false)
  const [loadingNewer, setLoadingNewer] = useState(false)
  const [hasOlder, setHasOlder] = useState(true)
  const [error, setError] = useState<string>()
  const completedInitialLoadKey = useRef<string | undefined>(undefined)
  const initialLoads = useRef(
    new Map<string, Promise<InitialChatLoadOutcome>>(),
  )
  const olderBeforeCursorKey = useRef<string | undefined>(
    undefined,
  )
  const newerAfterCursorKey = useRef<string | undefined>(
    undefined,
  )
  const targetLoads = useRef(new Map<MessageID, Promise<boolean>>())

  useEffect(() => {
    setError(undefined)
    const peerId = inputPeer(peer)
    const operations: Promise<unknown>[] = []
    if (dialog?.open !== true) {
      operations.push(
        realtime.mutateAccepted(
          updateDialogOpen({ peerId, open: true }),
        ),
      )
    }
    if (
      peer.peerKind === "chat" &&
      dialog?.chatListHidden === true
    ) {
      operations.push(
        realtime.mutateAccepted(showInChatList({ peerId })),
      )
    }
    // Apply the local dialog intents synchronously before starting the
    // background refresh. Opening a resident chat must never wait for a
    // getChat network round trip to appear in the Inbox.
    if (chatId == null) {
      operations.push(realtime.query(getChat({ peerId })))
    }
    if (operations.length === 0) return
    let active = true
    void Promise.all(operations).catch((cause: unknown) => {
      if (active) {
        setError(
          cause instanceof Error
            ? cause.message
            : "Could not load the chat.",
        )
      }
    })
    return () => {
      active = false
    }
  }, [
    chatId,
    dialog?.chatListHidden,
    dialog?.open,
    peer.peerId,
    peer.peerKind,
    realtime,
  ])

  useEffect(() => {
    if (chatId == null) return
    const loadKey = `${chatId}:prepared=${preparedChatId === chatId}:refresh=${preparedNeedsHistoryRefresh}`
    if (completedInitialLoadKey.current === loadKey) return
    olderBeforeCursorKey.current = undefined
    newerAfterCursorKey.current = undefined
    const hasPreparedInitialState = preparedChatId === chatId
    const shouldRefreshPreparedState =
      hasPreparedInitialState && preparedNeedsHistoryRefresh
    setInitialLoading(
      !hasPreparedInitialState || shouldRefreshPreparedState,
    )
    setHasOlder(true)
    setError(undefined)
    let operation = initialLoads.current.get(loadKey)
    if (!operation) {
      operation = (async (): Promise<InitialChatLoadOutcome> => {
        try {
          let hydratedMessageCount = 0
          if (!hasPreparedInitialState) {
            hydratedMessageCount = await db.hydrateMessageWindow(chatId, {
              limit: initialLimit,
            })
          }
          // Inline macOS hands the preloader's `messagesInitialState` directly
          // to the progressive list and starts observation after presentation.
          // Do not repeat that load and replace its stable first window.
          if (
            (hasPreparedInitialState && !shouldRefreshPreparedState) ||
            hydratedMessageCount > 0
          ) {
            return {}
          }
          const result = await realtime.query(
            getChatHistory({
              peerId: inputPeer(peer),
              limit: initialLimit,
              mode: GetChatHistoryMode.HISTORY_MODE_LATEST,
            }),
          )
          return {
            hasOlder:
              result?.oneofKind === "getChatHistory" &&
              result.getChatHistory.messages.length < initialLimit
                ? false
                : undefined,
          }
        } catch (cause) {
          return {
            error:
              cause instanceof Error
                ? cause.message
                : "Could not refresh messages.",
          }
        }
      })()
      initialLoads.current.set(loadKey, operation)
      void operation.finally(() => {
        if (initialLoads.current.get(loadKey) === operation) {
          initialLoads.current.delete(loadKey)
        }
      })
    }
    let active = true
    void operation.then((outcome) => {
      if (!active) return
      completedInitialLoadKey.current = loadKey
      if (outcome.hasOlder != null) setHasOlder(outcome.hasOlder)
      setError(outcome.error)
      setInitialLoading(false)
    })

    return () => {
      active = false
    }
  }, [
    chatId,
    db,
    peer.peerId,
    peer.peerKind,
    preparedChatId,
    preparedNeedsHistoryRefresh,
    realtime,
  ])

  const loadOlder = useCallback(
    async (before: MessageWindowCursor) => {
      const beforeKey = messageWindowCursorKey(before)
      if (
        chatId == null ||
        loadingOlder ||
        !hasOlder ||
        olderBeforeCursorKey.current === beforeKey
      ) {
        return
      }

      olderBeforeCursorKey.current = beforeKey
      setLoadingOlder(true)
      setError(undefined)

      try {
        await db.hydrateMessageWindow(chatId, {
          limit: olderLimit,
          before,
        })

        const result = await realtime.query(
          getChatHistory({
            peerId: inputPeer(peer),
            mode: GetChatHistoryMode.HISTORY_MODE_OLDER,
            beforeId: before.messageId,
            limit: olderLimit,
          }),
        )
        if (
          result?.oneofKind === "getChatHistory" &&
          result.getChatHistory.messages.length < olderLimit
        ) {
          setHasOlder(false)
        }
      } catch (cause) {
        olderBeforeCursorKey.current = undefined
        setError(cause instanceof Error ? cause.message : "Could not load older messages.")
      } finally {
        setLoadingOlder(false)
      }
    },
    [chatId, db, hasOlder, loadingOlder, peer.peerId, peer.peerKind, realtime],
  )

  const loadAround = useCallback(
    (targetMessageId: MessageID) => {
      if (chatId == null) return Promise.resolve(false)
      const existing = targetLoads.current.get(targetMessageId)
      if (existing) return existing
      const operation = loadChatWindowAroundMessage({
        db,
        realtime,
        peer,
        chatId,
        targetMessageId,
      })
        .catch((cause: unknown) => {
          setError(
            cause instanceof Error
              ? cause.message
              : "Could not find the message.",
          )
          return false
        })
        .finally(() => {
          targetLoads.current.delete(targetMessageId)
        })
      targetLoads.current.set(targetMessageId, operation)
      return operation
    },
    [chatId, db, peer.peerId, peer.peerKind, realtime],
  )

  const loadNewer = useCallback(
    async (after: MessageWindowCursor) => {
      const afterKey = messageWindowCursorKey(after)
      if (
        chatId == null ||
        loadingNewer ||
        newerAfterCursorKey.current === afterKey
      ) {
        return
      }

      newerAfterCursorKey.current = afterKey
      setLoadingNewer(true)
      setError(undefined)

      try {
        await db.hydrateMessageWindow(chatId, {
          limit: newerLimit,
          after,
        })
        await realtime.query(
          getChatHistory({
            peerId: inputPeer(peer),
            mode: GetChatHistoryMode.HISTORY_MODE_NEWER,
            afterId: after.messageId,
            limit: newerLimit,
          }),
        )
      } catch (cause) {
        newerAfterCursorKey.current = undefined
        setError(
          cause instanceof Error
            ? cause.message
            : "Could not load newer messages.",
        )
      } finally {
        setLoadingNewer(false)
      }
    },
    [
      chatId,
      db,
      loadingNewer,
      peer.peerId,
      peer.peerKind,
      realtime,
    ],
  )

  return {
    initialLoading,
    loadingOlder,
    loadingNewer,
    hasOlder,
    error,
    loadOlder,
    loadNewer,
    loadAround,
  }
}
