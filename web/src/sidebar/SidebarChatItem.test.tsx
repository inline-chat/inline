import { DbObjectKind, type Dialog } from "@inline/client"
import { chatId, dialogId } from "@inline/ids"
import {
  cleanup,
  fireEvent,
  render,
  screen,
} from "@testing-library/react"
import type { PropsWithChildren } from "react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { SidebarChatItem } from "./SidebarChatItem"

vi.mock("@stylexjs/stylex", () => ({
  create: <T,>(styles: T) => styles,
  defineVars: <T,>(tokens: T) => tokens,
  props: () => ({}),
}))

vi.mock("@tanstack/react-router", () => ({
  Link: ({ children }: PropsWithChildren) => (
    <a href="/chat/chat/801">{children}</a>
  ),
  useLocation: () => ({ pathname: "/chat/chat/801" }),
  useNavigate: () => vi.fn(),
}))

vi.mock("~/app/AppRoutePresentation", () => ({
  useAppRoutePresentation: () => ({
    begin: vi.fn(),
    finish: vi.fn(),
  }),
}))

vi.mock("~/inline/data/react", () => ({
  useInlineObject: (kind: DbObjectKind) =>
    kind === DbObjectKind.Chat
      ? {
          kind: DbObjectKind.Chat,
          id: chatId(801),
          title: "Native thread",
        }
      : undefined,
}))

vi.mock("~/inline/data/useInlineChatTitle", () => ({
  useInlineChatTitle: () => "Native thread",
}))

vi.mock("~/ui/Avatar", () => ({
  ThreadAvatar: () => <span aria-hidden="true" />,
  UserAvatar: () => <span aria-hidden="true" />,
}))

vi.mock("~/ui/InlineContextMenu", () => ({
  InlineContextMenu: ({ children, items: _items, ...props }: PropsWithChildren<{ items: unknown }>) => (
    <div {...props}>{children}</div>
  ),
}))

afterEach(cleanup)

const dialog = (changes: Partial<Dialog> = {}): Dialog => ({
  kind: DbObjectKind.Dialog,
  id: dialogId(-801),
  chatId: chatId(801),
  peerThreadId: chatId(801),
  open: true,
  unreadCount: 3,
  ...changes,
})

describe("SidebarChatItem Inbox controls", () => {
  it("replaces the unread badge with Inline's hover Close action", () => {
    const close = vi.fn()
    const item = dialog()
    render(
      <SidebarChatItem
        dialog={item}
        onClose={close}
        onTogglePinned={() => undefined}
        onToggleRead={() => undefined}
      />,
    )

    expect(screen.getByText("3")).toBeInTheDocument()
    const link = screen.getByRole("link")
    fireEvent.pointerEnter(link.parentElement!)
    expect(screen.queryByText("3")).toBeNull()

    const action = screen.getByRole("button", {
      name: "Close Native thread from sidebar",
    })
    expect(action).toHaveAttribute("title", "Close")
    fireEvent.click(action)
    expect(close).toHaveBeenCalledOnce()
    expect(close).toHaveBeenCalledWith(item)
  })

  it("does not expose Close for a pinned Inbox item", () => {
    render(
      <SidebarChatItem
        dialog={dialog({ pinned: true })}
        onClose={() => undefined}
        onTogglePinned={() => undefined}
        onToggleRead={() => undefined}
      />,
    )
    expect(
      screen.queryByRole("button", {
        name: /from sidebar/,
      }),
    ).toBeNull()
  })
})
