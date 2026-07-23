import { MessageSendingStatus, messageKey } from "@inline/client"
import { chatId, messageId, userId } from "@inline/ids"
import {
  cleanup,
  fireEvent,
  render,
  screen,
} from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import type { ChatMessageRow } from "./ChatRowListModel"
import { MessageBubble } from "./MessageBubble"

vi.mock("@stylexjs/stylex", () => ({
  create: <T,>(styles: T) => styles,
  defineVars: <T,>(tokens: T) => tokens,
  props: () => ({}),
}))

vi.mock("~/ui/InlineToast", () => ({
  useInlineToast: () => ({ show: vi.fn() }),
}))

afterEach(cleanup)

const targetChatId = chatId(10)
const temporaryMessageId = messageId(-90)
const failedMessage: ChatMessageRow = {
  id: messageKey(targetChatId, temporaryMessageId),
  messageId: temporaryMessageId,
  chatId: targetChatId,
  fromId: userId(7),
  out: true,
  date: 1_700_000_000,
  presentation: { text: "Try again" },
  status: MessageSendingStatus.Failed,
}

describe("MessageBubble failed-send action", () => {
  it("uses Inline's Resend action for the exact failed message", () => {
    const resend = vi.fn()
    render(
      <MessageBubble
        message={failedMessage}
        style="bubble"
        onOpenMessage={() => undefined}
        onOpenReplyThread={() => undefined}
        onResendMessage={resend}
        peer={{ peerKind: "chat", peerId: targetChatId }}
        currentUserId={userId(7)}
      />,
    )

    const action = screen.getByRole("button", {
      name: "Resend message",
    })
    expect(action).toHaveAttribute("title", "Resend")
    fireEvent.click(action)
    expect(resend).toHaveBeenCalledOnce()
    expect(resend).toHaveBeenCalledWith(temporaryMessageId)
  })
})
