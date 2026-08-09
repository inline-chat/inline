import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react"
import type { Transaction } from "@inline/client"
import { chatId, messageId } from "@inline/ids"
import { afterEach, describe, expect, it, vi } from "vitest"
import { MessageActionRowsView } from "./MessageActionRowsView"

const actionResult = {
  oneofKind: "invokeMessageAction" as const,
  invokeMessageAction: { interactionId: 42n },
}
const mutate = vi.fn(async (_transaction: Transaction) => actionResult)
const waitForMessageActionAnswer = vi.fn(async () => undefined as
  | {
      interactionId: bigint
      ui?: {
        kind: {
          oneofKind: "toast"
          toast: { text: string }
        }
      }
    }
  | undefined)
const copy = vi.fn(async (_value: string) => undefined)
const show = vi.fn()

vi.mock("@stylexjs/stylex", () => ({
  create: <T,>(styles: T) => styles,
  defineVars: <T,>(tokens: T) => tokens,
  props: () => ({}),
}))

vi.mock("@inline/client", async (importOriginal) => {
  const actual = await importOriginal<typeof import("@inline/client")>()
  return {
    ...actual,
    useRealtimeClient: () => ({ mutate, waitForMessageActionAnswer }),
  }
})

vi.mock("~/ui/InlineClipboard", () => ({
  writeInlineClipboardText: (value: string) => copy(value),
}))

vi.mock("~/ui/InlineToast", () => ({
  useInlineToast: () => ({ show }),
}))

afterEach(() => {
  cleanup()
  mutate.mockClear()
  waitForMessageActionAnswer.mockClear()
  waitForMessageActionAnswer.mockResolvedValue(undefined)
  copy.mockClear()
  show.mockClear()
})

describe("MessageActionRowsView", () => {
  it("runs callback actions and keeps copy actions local", async () => {
    render(
      <MessageActionRowsView
        actions={{
          rows: [[
            { id: "approve", label: "Approve", kind: "callback" },
            { id: "copy", label: "Copy ID", kind: "copyText", text: "ENG-42" },
          ]],
        }}
        chatId={chatId(10)}
        messageId={messageId(20)}
        peer={{ peerKind: "chat", peerId: chatId(10) }}
      />,
    )

    fireEvent.click(screen.getByRole("button", { name: "Approve" }))
    await waitFor(() => expect(mutate).toHaveBeenCalledOnce())
    const transaction = mutate.mock.calls[0]![0]
    expect(transaction.input(transaction.context)).toMatchObject({
      oneofKind: "invokeMessageAction",
      invokeMessageAction: { actionId: "approve", messageId: 20n },
    })
    await waitFor(() =>
      expect(waitForMessageActionAnswer).toHaveBeenCalledWith(42n),
    )

    fireEvent.click(screen.getByRole("button", { name: "Copy ID" }))
    await waitFor(() => expect(copy).toHaveBeenCalledWith("ENG-42"))
    expect(mutate).toHaveBeenCalledOnce()
  })

  it("runs one callback until its asynchronous bot answer settles", async () => {
    let settle: ((answer: {
      interactionId: bigint
      ui: {
        kind: {
          oneofKind: "toast"
          toast: { text: string }
        }
      }
    }) => void) | undefined
    waitForMessageActionAnswer.mockImplementationOnce(
      () => new Promise((resolve) => {
        settle = resolve
      }),
    )
    render(
      <MessageActionRowsView
        actions={{
          rows: [[{ id: "approve", label: "Approve", kind: "callback" }]],
        }}
        chatId={chatId(10)}
        messageId={messageId(20)}
        peer={{ peerKind: "chat", peerId: chatId(10) }}
      />,
    )

    const button = screen.getByRole("button", { name: "Approve" })
    fireEvent.click(button)
    fireEvent.click(button)

    expect(mutate).toHaveBeenCalledOnce()
    expect(button).toBeDisabled()
    await waitFor(() =>
      expect(waitForMessageActionAnswer).toHaveBeenCalledWith(42n),
    )
    settle?.({
      interactionId: 42n,
      ui: {
        kind: {
          oneofKind: "toast",
          toast: { text: "Approved" },
        },
      },
    })
    await waitFor(() => expect(button).not.toBeDisabled())
    expect(show).toHaveBeenCalledWith("Approved")
  })
})
