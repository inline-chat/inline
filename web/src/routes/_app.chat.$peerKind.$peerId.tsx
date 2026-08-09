import { createFileRoute, useLocation } from "@tanstack/react-router"
import { ChatView } from "~/chat/ChatView"
import {
  inlineRouteErrorTitle,
  RoutePlaceholderView,
} from "~/app/RoutePlaceholderView"
import { parsePeerRoute } from "~/inline/data/peer"
import { parseInlineId, type MessageID } from "@inline/ids"
import { useEffect } from "react"
import { logInlineRouteError } from "~/inline/logging/InlineLogging"
import { useAppRoutePresentationReady } from "~/app/AppRoutePresentation"

type ChatRouteSearch = {
  messageId?: MessageID
}

export const Route = createFileRoute("/_app/chat/$peerKind/$peerId")({
  validateSearch: (search: Record<string, unknown>): ChatRouteSearch => ({
    messageId: parseInlineId<"message">(search.messageId, {
      positive: true,
    }),
  }),
  loaderDeps: ({ search }) => ({ messageId: search.messageId }),
  component: ChatRoute,
  errorComponent: ChatRouteError,
  head: () => ({
    meta: [{ title: "Inline" }],
  }),
})

function ChatRouteError({
  error,
  reset,
}: {
  error: unknown
  reset: () => void
}) {
  const location = useLocation()
  useAppRoutePresentationReady(location.pathname)
  useEffect(() => {
    logInlineRouteError("chat", error)
  }, [error])
  return (
    <RoutePlaceholderView
      title={inlineRouteErrorTitle(
        error,
        "Inline couldn’t open this chat.",
      )}
      actionTitle="Try Again"
      onAction={reset}
    />
  )
}

function ChatRoute() {
  const params = Route.useParams()
  const search = Route.useSearch()
  const peer = parsePeerRoute(params.peerKind, params.peerId)
  if (!peer) {
    return <InvalidChatRoute />
  }
  return (
    <ChatView
      key={`${peer.peerKind}:${peer.peerId}`}
      peer={peer}
      targetMessageId={search.messageId}
    />
  )
}

function InvalidChatRoute() {
  const location = useLocation()
  useAppRoutePresentationReady(location.pathname)
  return <RoutePlaceholderView title="This chat isn’t available." />
}
