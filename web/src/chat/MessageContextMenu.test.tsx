import { MessageSendingStatus, messageKey } from "@inline/client"
import { chatId, messageId, userId } from "@inline/ids"
import { cleanup, render, screen } from "@testing-library/react"
import type { PropsWithChildren } from "react"
import { afterEach, describe, expect, it, vi } from "vitest"
import type { ChatMessageRow } from "./ChatRowListModel"
import { MessageContextMenu } from "./MessageContextMenu"

vi.mock("@stylexjs/stylex", () => ({
  create: <T,>(styles: T) => styles,
  defineVars: <T,>(tokens: T) => tokens,
  props: () => ({}),
}))

vi.mock("~/ui/InlineContextMenu", () => ({
  InlineContextMenu: ({
    children,
    items,
  }: PropsWithChildren<{
    items: readonly { label: string }[]
  }>) => (
    <div>
      {children}
      {items.map((item) => <span key={item.label}>{item.label}</span>)}
    </div>
  ),
}))

vi.mock("~/ui/InlineToast", () => ({
  useInlineToast: () => ({ show: vi.fn() }),
}))

afterEach(cleanup)

const row = (
  changes: Partial<ChatMessageRow> = {},
): ChatMessageRow => ({
  id: messageKey(chatId(10), messageId(20)),
  chatId: chatId(10),
  messageId: messageId(20),
  fromId: userId(30),
  out: false,
  presentation: { text: "Hello" },
  ...changes,
})

const renderMenu = (message: ChatMessageRow) =>
  render(
    <MessageContextMenu
      message={message}
      pinned={false}
      onReply={vi.fn()}
      onReplyThread={vi.fn()}
      onEdit={vi.fn()}
      onDelete={vi.fn()}
      onForward={vi.fn()}
      onAddReaction={vi.fn()}
      onTogglePin={vi.fn()}
      onResend={vi.fn()}
    >
      <span>Message</span>
    </MessageContextMenu>,
  )

describe("MessageContextMenu action policy", () => {
  it("offers reference actions without destructive incoming-message actions", () => {
    renderMenu(row())

    for (const label of [
      "Reply",
      "Reply in Thread",
      "Copy Text",
      "Copy Link",
      "Add Reaction",
      "Forward…",
      "Pin",
    ]) {
      expect(screen.getByText(label)).toBeInTheDocument()
    }
    expect(screen.queryByText("Edit…")).toBeNull()
    expect(screen.queryByText("Delete…")).toBeNull()
    expect(screen.queryByText("Cancel Send")).toBeNull()
  })

  it("gates edit/delete to confirmed own messages", () => {
    renderMenu(row({ out: true }))
    expect(screen.getByText("Edit…")).toBeInTheDocument()
    expect(screen.getByText("Delete…")).toBeInTheDocument()
  })

  it("keeps failed local messages cancellable and resendable", () => {
    renderMenu(row({
      id: messageKey(chatId(10), messageId(-20)),
      messageId: messageId(-20),
      out: true,
      status: MessageSendingStatus.Failed,
    }))
    expect(screen.getByText("Resend")).toBeInTheDocument()
    expect(screen.getByText("Cancel Send")).toBeInTheDocument()
    expect(screen.queryByText("Reply")).toBeNull()
    expect(screen.queryByText("Pin")).toBeNull()
  })
})
