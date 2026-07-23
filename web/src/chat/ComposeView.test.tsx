import {
  AuthStore,
  Db,
  DbObjectKind,
  MessageSendingStatus,
  messageKey,
  type RealtimeService,
  type SendMessageTransaction,
} from "@inline/client/core"
import { InlineClientProvider } from "@inline/client/react"
import { chatId, messageId, userId } from "@inline/ids"
import {
  act,
  cleanup,
  fireEvent,
  render,
  screen,
  waitFor,
} from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import type { InlineMessageDraftsService } from "../inline/drafts/InlineMessageDrafts"
import { InlineMessageDraftsProvider } from "../inline/drafts/InlineMessageDraftsContext"
import { ComposeView } from "./ComposeView"
import type { ChatMessageRow } from "./ChatRowListModel"

vi.mock("@stylexjs/stylex", () => ({
  create: <T,>(styles: T) => styles,
  defineVars: <T,>(tokens: T) => tokens,
  props: () => ({}),
}))

vi.mock("./compose/InlineComposeEditor", async () => {
  const React = await import("react")
  return {
    InlineComposeEditor: React.forwardRef(
      (
        {
          value,
          onChange,
        }: {
          value: { text: string }
          onChange: (value: { text: string }) => void
        },
        ref,
      ) => {
        React.useImperativeHandle(ref, () => ({
          focus: () => undefined,
          clear: () => undefined,
        }))
        return (
          <textarea
            aria-label="Message"
            value={value.text}
            onChange={(event) =>
              onChange({ text: event.currentTarget.value })
            }
          />
        )
      },
    ),
  }
})

afterEach(cleanup)

const targetChatId = chatId(10)
const peer = { peerKind: "user" as const, peerId: userId(8) }

const deferred = <T,>() => {
  let resolve!: (value: T) => void
  const promise = new Promise<T>((next) => {
    resolve = next
  })
  return { promise, resolve }
}

const renderCompose = (
  mutate: RealtimeService["mutate"],
  options: {
    replyTarget?: ChatMessageRow
    onReplyAccepted?: (messageId: ChatMessageRow["messageId"]) => void
  } = {},
) => {
  const db = new Db({ autoHydrate: false, persistence: false })
  const auth = new AuthStore({ persistence: "memory" })
  auth.login({ token: "token", userId: userId(7) })
  const realtime = {
    connectionState: "connected",
    mutate,
  } as RealtimeService
  const drafts: InlineMessageDraftsService = {
    load: vi.fn(async () => undefined),
    update: vi.fn(async () => undefined),
    clear: vi.fn(async () => undefined),
  }
  render(
    <InlineClientProvider value={{ auth, db, realtime }}>
      <InlineMessageDraftsProvider drafts={drafts}>
        <ComposeView
          peer={peer}
          chatId={targetChatId}
          recipientName="Dena"
          replyTarget={options.replyTarget}
          onCancelReply={() => undefined}
          onReplyAccepted={options.onReplyAccepted}
        />
      </InlineMessageDraftsProvider>
    </InlineClientProvider>,
  )
  return { db, drafts }
}

const optimisticMessage = (
  transaction: SendMessageTransaction,
) => {
  const temporaryMessageId =
    transaction.context.temporaryMessageId!
  return {
    kind: DbObjectKind.Message as const,
    id: messageKey(targetChatId, temporaryMessageId),
    chatId: targetChatId,
    messageId: temporaryMessageId,
    fromId: userId(7),
    out: true,
    message: transaction.context.text,
    status: MessageSendingStatus.Sending,
  }
}

describe("ComposeView send acceptance", () => {
  it("keeps the draft when the owner rejects local acceptance", async () => {
    const failure = new Error("local outbox commit failed")
    const mutate = vi.fn<RealtimeService["mutate"]>(async () => {
      throw failure
    })
    const { drafts } = renderCompose(mutate)
    const input = screen.getByRole("textbox", { name: "Message" })
    fireEvent.change(input, { target: { value: "Keep this" } })
    fireEvent.click(screen.getByRole("button", { name: "Send" }))

    await screen.findByRole("alert")
    expect(input).toHaveValue("Keep this")
    expect(drafts.clear).not.toHaveBeenCalled()
  })

  it("clears only after the optimistic message is projected, without waiting for network", async () => {
    const network = deferred<undefined>()
    const mutate = vi.fn<RealtimeService["mutate"]>(
      () => network.promise,
    )
    const { db, drafts } = renderCompose(mutate)
    const input = screen.getByRole("textbox", { name: "Message" })
    fireEvent.change(input, { target: { value: "Queue this" } })
    fireEvent.click(screen.getByRole("button", { name: "Send" }))
    await waitFor(() => expect(mutate).toHaveBeenCalledOnce())
    expect(input).toHaveValue("Queue this")
    expect(drafts.clear).not.toHaveBeenCalled()

    const transaction = mutate.mock.calls[0]![0] as SendMessageTransaction
    act(() => db.insert(optimisticMessage(transaction)))
    await waitFor(() => expect(drafts.clear).toHaveBeenCalledOnce())
    expect(input).toHaveValue("")
    network.resolve(undefined)
  })

  it("does not clear text typed after the submitted message", async () => {
    const network = deferred<undefined>()
    const mutate = vi.fn<RealtimeService["mutate"]>(
      () => network.promise,
    )
    const { db, drafts } = renderCompose(mutate)
    const input = screen.getByRole("textbox", { name: "Message" })
    fireEvent.change(input, { target: { value: "First message" } })
    fireEvent.click(screen.getByRole("button", { name: "Send" }))
    await waitFor(() => expect(mutate).toHaveBeenCalledOnce())
    fireEvent.change(input, { target: { value: "New draft" } })

    const transaction = mutate.mock.calls[0]![0] as SendMessageTransaction
    act(() => db.insert(optimisticMessage(transaction)))
    await waitFor(() =>
      expect(
        screen.getByRole("button", { name: "Send" }),
      ).not.toBeDisabled(),
    )
    expect(input).toHaveValue("New draft")
    expect(drafts.clear).not.toHaveBeenCalled()
    network.resolve(undefined)
  })

  it("keeps the exact reply target through optimistic acceptance", async () => {
    const network = deferred<undefined>()
    const mutate = vi.fn<RealtimeService["mutate"]>(
      () => network.promise,
    )
    const repliedToMessageId = messageId(4)
    const replyTarget: ChatMessageRow = {
      id: messageKey(targetChatId, repliedToMessageId),
      messageId: repliedToMessageId,
      chatId: targetChatId,
      fromId: userId(8),
      out: false,
      presentation: { text: "Original message" },
    }
    const onReplyAccepted = vi.fn()
    const { db } = renderCompose(mutate, {
      replyTarget,
      onReplyAccepted,
    })
    fireEvent.change(screen.getByRole("textbox", { name: "Message" }), {
      target: { value: "Reply" },
    })
    fireEvent.click(screen.getByRole("button", { name: "Send" }))
    await waitFor(() => expect(mutate).toHaveBeenCalledOnce())

    const transaction = mutate.mock.calls[0]![0] as SendMessageTransaction
    expect(transaction.context.replyToMsgId).toBe(repliedToMessageId)
    act(() => db.insert(optimisticMessage(transaction)))
    await waitFor(() =>
      expect(onReplyAccepted).toHaveBeenCalledWith(repliedToMessageId),
    )
    network.resolve(undefined)
  })
})
