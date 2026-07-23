import { createFileRoute } from "@tanstack/react-router"
import { ChatView } from "~/chat/ChatView"
import {
  inlineRouteErrorTitle,
  RoutePlaceholderView,
} from "~/app/RoutePlaceholderView"
import { parsePeerRoute } from "~/inline/data/peer"
import { parseInlineId, type MessageID } from "@inline/ids"

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
  errorComponent: ({ error, reset }) => (
    <RoutePlaceholderView
      title={inlineRouteErrorTitle(
        error,
        "Inline couldn’t open this chat.",
      )}
      actionTitle="Try Again"
      onAction={reset}
    />
  ),
  head: () => ({
    meta: [{ title: "Inline" }],
  }),
})

function ChatRoute() {
  const params = Route.useParams()
  const search = Route.useSearch()
  const peer = parsePeerRoute(params.peerKind, params.peerId)
  if (!peer) {
    return <RoutePlaceholderView title="This chat isn’t available." />
  }
  return (
    <ChatView
      key={`${peer.peerKind}:${peer.peerId}`}
      peer={peer}
      targetMessageId={search.messageId}
    />
  )
}
