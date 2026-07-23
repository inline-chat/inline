import {
  createContext,
  useContext,
  useEffect,
  useMemo,
  useSyncExternalStore,
  type ReactNode,
} from "react"
import type { ChatID, MessageID } from "@inline/ids"
import type { InlinePeerRoute } from "../data/peer"
import { inputPeer } from "../data/peer"
import type { InlineMessageReferencesService } from "./InlineMessageReferences"

const InlineMessageReferencesContext =
  createContext<InlineMessageReferencesService | null>(null)

export function InlineMessageReferencesProvider({
  references,
  children,
}: {
  references: InlineMessageReferencesService
  children: ReactNode
}) {
  return (
    <InlineMessageReferencesContext.Provider value={references}>
      {children}
    </InlineMessageReferencesContext.Provider>
  )
}

export const useInlineMessageReferences = (
  peer: InlinePeerRoute,
  chatId: ChatID | undefined,
  messageIds: MessageID[],
  refreshKey?: string,
) => {
  const references = useContext(InlineMessageReferencesContext)
  if (!references) {
    throw new Error(
      "useInlineMessageReferences must be used within InlineRuntime",
    )
  }
  const revision = useSyncExternalStore(
    references.subscribe,
    references.getSnapshot,
    references.getSnapshot,
  )
  const key = messageIds.join(",")
  const uniqueIds = useMemo(
    () => Array.from(new Set(messageIds)),
    [key],
  )

  useEffect(() => {
    if (!chatId || uniqueIds.length === 0) return
    void references
      .load({
        peerId: inputPeer(peer),
        chatId,
        messageIds: uniqueIds,
      })
      .catch(() => undefined)
  }, [chatId, peer.peerId, peer.peerKind, references, refreshKey, uniqueIds])

  return useMemo(
    () =>
      new Map(
        uniqueIds.flatMap((id) => {
          const message = chatId
            ? references.peek(chatId, id)
            : undefined
          return message ? [[id, message] as const] : []
        }),
      ),
    [chatId, references, revision, uniqueIds],
  )
}
