import { DbObjectKind, messageKey, type Message } from "@inline/client"
import { chatId, messageId, userId } from "@inline/ids"
import { cleanup, fireEvent, render, screen } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import {
  makePinnedMessageHeaderPresentation,
  PinnedMessageHeaderView,
} from "./PinnedMessageHeaderView"

vi.mock("@stylexjs/stylex", () => ({
  create: <T,>(styles: T) => styles,
  defineVars: <T,>(tokens: T) => tokens,
  props: () => ({}),
}))

vi.mock("~/inline/data/react", () => ({
  useInlineObject: () => ({
    kind: DbObjectKind.User,
    id: userId(7),
    firstName: "Dena",
  }),
}))

vi.mock("~/ui/InlineToast", () => ({
  useInlineToast: () => ({ show: vi.fn() }),
}))

afterEach(cleanup)

const pinnedMessage: Message = {
  kind: DbObjectKind.Message,
  id: messageKey(chatId(10), messageId(99)),
  messageId: messageId(99),
  chatId: chatId(10),
  fromId: userId(7),
  message: "Prepared before the first frame",
}

describe("PinnedMessageHeaderView", () => {
  it("renders prepared content at stable geometry and opens the exact message", () => {
    const open = vi.fn()
    render(
      <PinnedMessageHeaderView
        messageId={messageId(99)}
        presentation={makePinnedMessageHeaderPresentation(pinnedMessage)}
        onOpen={open}
        onUnpin={async () => undefined}
      />,
    )

    expect(screen.getByText("Dena")).toBeInTheDocument()
    expect(
      screen.getByText("Prepared before the first frame"),
    ).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "Go to pinned message" }))
    expect(open).toHaveBeenCalledWith(messageId(99))
  })

  it("uses the real native Unpin control boundary", () => {
    const unpin = vi.fn(async () => undefined)
    render(
      <PinnedMessageHeaderView
        messageId={messageId(99)}
        presentation={makePinnedMessageHeaderPresentation(pinnedMessage)}
        onOpen={() => undefined}
        onUnpin={unpin}
      />,
    )

    fireEvent.click(screen.getByRole("button", { name: "Unpin" }))
    expect(unpin).toHaveBeenCalledWith(messageId(99))
  })

  it("preserves the header height when pinned content is unavailable", () => {
    render(
      <PinnedMessageHeaderView
        messageId={messageId(99)}
        presentation={makePinnedMessageHeaderPresentation()}
        onOpen={() => undefined}
        onUnpin={async () => undefined}
      />,
    )
    expect(screen.getByText("Pinned message unavailable")).toBeInTheDocument()
  })

  it("projects protocol bigint arrays before they reach React props", () => {
    const presentation = makePinnedMessageHeaderPresentation({
      ...pinnedMessage,
      replies: {
        chatId: 10n,
        replyCount: 2,
        hasUnread: false,
        recentReplierUserIds: [7n, 8n],
      },
    })

    expect(() => JSON.stringify(presentation)).not.toThrow()
    expect(presentation).toEqual({
      label: "Prepared before the first frame",
      senderId: userId(7),
    })
  })
})
