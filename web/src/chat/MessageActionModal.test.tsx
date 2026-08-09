import {
  MessageSendingStatus,
  messageKey,
  type Transaction,
} from "@inline/client"
import { MessageEntity_Type } from "@inline-chat/protocol/core"
import { chatId, messageId, userId } from "@inline/ids"
import {
  cleanup,
  fireEvent,
  render,
  screen,
  waitFor,
} from "@testing-library/react"
import type { ButtonHTMLAttributes, InputHTMLAttributes, ReactNode } from "react"
import { afterEach, describe, expect, it, vi } from "vitest"
import type { ChatMessageRow } from "./ChatRowListModel"
import { MessageActionModal } from "./MessageActionModal"

const runtime = vi.hoisted(() => ({
  connectionState: "connected",
  mutate: vi.fn(async (_transaction: Transaction): Promise<void> => undefined),
  cancelPendingMessage: vi.fn(async () => true),
  show: vi.fn(),
}))

vi.mock("@stylexjs/stylex", () => ({
  create: <T,>(styles: T) => styles,
  defineVars: <T,>(tokens: T) => tokens,
  props: () => ({}),
}))

vi.mock("@inline/client", async (importOriginal) => {
  const actual = await importOriginal<typeof import("@inline/client")>()
  return {
    ...actual,
    useInlineClient: () => ({
      realtime: {
        get connectionState() {
          return runtime.connectionState
        },
        mutate: runtime.mutate,
        cancelPendingMessage: runtime.cancelPendingMessage,
      },
    }),
  }
})

vi.mock("~/inline/data/react", () => ({
  useInlineObject: () => undefined,
  useInlineQuery: () => [],
}))

vi.mock("~/inline/data/useInlineChatTitle", () => ({
  useInlineChatTitle: () => undefined,
}))

vi.mock("~/ui/Avatar", () => ({
  ThreadAvatar: () => null,
  UserAvatar: () => null,
}))

vi.mock("~/ui/InlineButton", () => ({
  InlineButton: (props: ButtonHTMLAttributes<HTMLButtonElement>) => (
    <button {...props} />
  ),
}))

vi.mock("~/ui/InlineModal", () => ({
  InlineModal: ({
    open,
    title,
    children,
    footer,
  }: {
    open: boolean
    title: string
    children: ReactNode
    footer?: ReactNode
  }) => open ? (
    <div role="dialog" aria-label={title}>
      {children}
      {footer}
    </div>
  ) : null,
}))

vi.mock("~/ui/InlineTextInput", () => ({
  InlineTextInput: (props: InputHTMLAttributes<HTMLInputElement>) => (
    <input {...props} />
  ),
}))

vi.mock("~/ui/InlineToast", () => ({
  useInlineToast: () => ({ show: runtime.show }),
}))

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
  runtime.connectionState = "connected"
  runtime.cancelPendingMessage.mockResolvedValue(true)
  runtime.mutate.mockResolvedValue(undefined)
})

const row = (
  changes: Partial<ChatMessageRow> = {},
): ChatMessageRow => ({
  id: messageKey(chatId(10), messageId(20)),
  chatId: chatId(10),
  messageId: messageId(20),
  fromId: userId(30),
  out: true,
  presentation: { text: "Original" },
  ...changes,
})

const peer = { peerKind: "chat", peerId: chatId(10) } as const

describe("MessageActionModal", () => {
  it("submits an edit and closes only after the transaction settles", async () => {
    let settle: (() => void) | undefined
    runtime.mutate.mockImplementationOnce(
      () => new Promise<void>((resolve) => {
        settle = resolve
      }),
    )
    const close = vi.fn()
    render(
      <MessageActionModal
        state={{ kind: "edit", message: row() }}
        peer={peer}
        onClose={close}
      />,
    )

    fireEvent.change(screen.getByRole("textbox"), {
      target: { value: "Updated" },
    })
    fireEvent.click(screen.getByRole("button", { name: "Save" }))
    expect(close).not.toHaveBeenCalled()
    const transaction = runtime.mutate.mock.calls[0]![0]
    expect(transaction.input(transaction.context)).toMatchObject({
      oneofKind: "editMessage",
      editMessage: { messageId: 20n, text: "Updated" },
    })

    settle?.()
    await waitFor(() => expect(close).toHaveBeenCalledOnce())
  })

  it("submits transformed entities with an edited message", async () => {
    const close = vi.fn()
    render(
      <MessageActionModal
        state={{
          kind: "edit",
          message: row({
            presentation: {
              text: "Hello @Dena",
              entities: {
                entities: [
                  {
                    type: MessageEntity_Type.MENTION,
                    offset: 6n,
                    length: 5n,
                    entity: {
                      oneofKind: "mention",
                      mention: { userId: 7n },
                    },
                  },
                ],
              },
            },
          }),
        }}
        peer={peer}
        onClose={close}
      />,
    )

    fireEvent.change(screen.getByRole("textbox"), {
      target: { value: "Really Hello @Dena" },
    })
    fireEvent.change(screen.getByRole("textbox"), {
      target: { value: "Really Hello @Dena!" },
    })
    fireEvent.click(screen.getByRole("button", { name: "Save" }))

    const transaction = runtime.mutate.mock.calls[0]![0]
    expect(transaction.input(transaction.context)).toMatchObject({
      oneofKind: "editMessage",
      editMessage: {
        text: "Really Hello @Dena!",
        entities: {
          entities: [{
            type: MessageEntity_Type.MENTION,
            offset: 13n,
            length: 5n,
          }],
        },
      },
    })
    await waitFor(() => expect(close).toHaveBeenCalledOnce())
  })

  it("rejects remote actions immediately while disconnected", async () => {
    runtime.connectionState = "idle"
    const close = vi.fn()
    render(
      <MessageActionModal
        state={{ kind: "edit", message: row() }}
        peer={peer}
        onClose={close}
      />,
    )

    fireEvent.click(screen.getByRole("button", { name: "Save" }))

    expect(runtime.mutate).not.toHaveBeenCalled()
    expect(screen.getByRole("alert")).toHaveTextContent(
      "Connect to Inline before updating this message.",
    )
    expect(close).not.toHaveBeenCalled()
  })

  it("remains dismissible while an accepted action is pending", async () => {
    let settle: (() => void) | undefined
    runtime.mutate.mockImplementationOnce(
      () => new Promise<void>((resolve) => {
        settle = resolve
      }),
    )
    const close = vi.fn()
    render(
      <MessageActionModal
        state={{ kind: "edit", message: row() }}
        peer={peer}
        onClose={close}
      />,
    )

    fireEvent.click(screen.getByRole("button", { name: "Save" }))
    fireEvent.click(screen.getByRole("button", { name: "Cancel" }))
    expect(close).toHaveBeenCalledOnce()

    settle?.()
    await waitFor(() => expect(runtime.mutate).toHaveBeenCalledOnce())
    expect(close).toHaveBeenCalledOnce()
  })

  it("cancels a failed durable local send without issuing an RPC", async () => {
    const close = vi.fn()
    const failed = row({
      id: messageKey(chatId(10), messageId(-20)),
      messageId: messageId(-20),
      status: MessageSendingStatus.Failed,
    })
    render(
      <MessageActionModal
        state={{ kind: "delete", message: failed }}
        peer={peer}
        onClose={close}
      />,
    )

    fireEvent.click(screen.getByRole("button", { name: "Cancel Send" }))
    await waitFor(() => expect(
      runtime.cancelPendingMessage,
    ).toHaveBeenCalledWith(chatId(10), messageId(-20)))
    expect(runtime.mutate).not.toHaveBeenCalled()
    expect(close).toHaveBeenCalledOnce()
  })
})
