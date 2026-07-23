import { useNavigate } from "@tanstack/react-router"
import type {
  ComponentPropsWithoutRef,
  FocusEvent,
  MouseEvent,
  PointerEvent,
} from "react"
import { prepareChatOpenIntent } from "~/chat/ChatOpenPreloader"
import type { InlinePeerRoute } from "~/inline/data/peer"

type InlineChatLinkProps = Omit<
  ComponentPropsWithoutRef<"a">,
  "href"
> & {
  peer: InlinePeerRoute
}

const shouldUseBrowserNavigation = (
  event: MouseEvent<HTMLAnchorElement>,
) =>
  event.button !== 0 ||
  event.metaKey ||
  event.ctrlKey ||
  event.shiftKey ||
  event.altKey ||
  (event.currentTarget.target !== "" &&
    event.currentTarget.target !== "_self")

/**
 * Inline-owned chat navigation keeps real anchor semantics while avoiding
 * TanStack Link's transition-flag `flushSync`. Cache warming is product-owned
 * as well, so speculative intent never creates a cancellable route match.
 */
export function InlineChatLink({
  peer,
  onClick,
  onPointerEnter,
  onFocus,
  ...props
}: InlineChatLinkProps) {
  const navigate = useNavigate()
  const href = `/chat/${peer.peerKind}/${peer.peerId}`
  const prepare = () => prepareChatOpenIntent(peer)
  const handleClick = (event: MouseEvent<HTMLAnchorElement>) => {
    onClick?.(event)
    if (event.defaultPrevented || shouldUseBrowserNavigation(event)) {
      return
    }
    event.preventDefault()
    // Intent warming is an optional first-frame optimization. Never make the
    // user's navigation wait for cache hydration or owner recovery: the route
    // adopts a preparation only when pointer/focus warming already completed.
    void prepare()
    void navigate({
      to: "/chat/$peerKind/$peerId",
      params: {
        peerKind: peer.peerKind,
        peerId: String(peer.peerId),
      },
    })
  }
  const handlePointerEnter = (
    event: PointerEvent<HTMLAnchorElement>,
  ) => {
    prepare()
    onPointerEnter?.(event)
  }
  const handleFocus = (event: FocusEvent<HTMLAnchorElement>) => {
    prepare()
    onFocus?.(event)
  }

  return (
    <a
      {...props}
      href={href}
      onClick={handleClick}
      onPointerEnter={handlePointerEnter}
      onFocus={handleFocus}
    />
  )
}
