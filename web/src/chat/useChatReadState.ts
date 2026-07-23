import {
  readMessages,
  useRealtimeClient,
  type Dialog,
} from "@inline/client"
import type { MessageID } from "@inline/ids"
import {
  useCallback,
  useEffect,
  useMemo,
  useState,
} from "react"
import { inputPeer, type InlinePeerRoute } from "~/inline/data/peer"
import {
  ChatReadStateCoordinator,
  isChatDocumentActive,
} from "./ChatReadState"

const currentDocumentActive = () =>
  typeof document !== "undefined" &&
  isChatDocumentActive(document)

export const useChatReadState = ({
  peer,
  dialog,
  latestMessageId,
}: {
  peer: InlinePeerRoute
  dialog?: Dialog
  latestMessageId?: MessageID
}) => {
  const realtime = useRealtimeClient()
  const [active, setActive] = useState(currentDocumentActive)
  const [atBottom, setAtBottom] = useState(false)
  const needsRead =
    Boolean(dialog?.unreadMark) || (dialog?.unreadCount ?? 0) > 0
  const coordinator = useMemo(
    () =>
      new ChatReadStateCoordinator({
        send: async (maxId) => {
          await realtime.mutateAccepted(
            readMessages({
              peerId: inputPeer(peer),
              maxId,
            }),
          )
        },
        onError: (error) => {
          console.error("Could not mark Inline chat as read", error)
        },
      }),
    [peer.peerId, peer.peerKind, realtime],
  )

  useEffect(() => {
    coordinator.activate()
    return () => coordinator.dispose()
  }, [coordinator])

  useEffect(() => {
    if (typeof window === "undefined" || typeof document === "undefined") {
      return
    }
    const update = () => setActive(currentDocumentActive())
    window.addEventListener("focus", update)
    window.addEventListener("blur", update)
    window.addEventListener("pageshow", update)
    window.addEventListener("pagehide", update)
    document.addEventListener("visibilitychange", update)
    update()
    return () => {
      window.removeEventListener("focus", update)
      window.removeEventListener("blur", update)
      window.removeEventListener("pageshow", update)
      window.removeEventListener("pagehide", update)
      document.removeEventListener("visibilitychange", update)
    }
  }, [])

  useEffect(() => {
    coordinator.observe({
      active,
      atBottom,
      needsRead,
      latestMessageId,
    })
  }, [active, atBottom, coordinator, latestMessageId, needsRead])

  const onBottomStateChange = useCallback((nextAtBottom: boolean) => {
    setAtBottom(nextAtBottom)
  }, [])
  return {
    active,
    atBottom,
    needsRead,
    latestMessageId,
    onBottomStateChange,
  }
}
