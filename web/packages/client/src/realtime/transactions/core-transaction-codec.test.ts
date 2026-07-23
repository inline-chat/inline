import { Method } from "@inline-chat/protocol/core"
import { chatId, messageId } from "@inline/ids"
import { describe, expect, it } from "vitest"
import {
  decodeCoreTransaction,
  encodeCoreTransaction,
  UnsupportedCoreTransaction,
} from "./core-transaction-codec"
import { getChatHistory } from "./get-chat-history"
import { GetChatHistoryMode } from "./get-chat-history"
import { logOut } from "./log-out"
import { sendMessage } from "./send-message"
import { readMessages } from "./read-messages"
import { addReaction } from "./add-reaction"
import { updateDialogOrder } from "./update-dialog-order"
import { updateDialogFollowMode } from "./update-dialog-follow-mode"
import { pinMessage } from "./pin-message"

describe("Inline core transaction codec", () => {
  it("round-trips exact IDs and generated send identity", () => {
    const original = sendMessage({
      chatId: chatId("9007199254740993"),
      replyToMsgId: messageId("9007199254740995"),
      text: "hello",
    })

    const decoded = decodeCoreTransaction(
      structuredClone(encodeCoreTransaction(original)),
    )

    expect(decoded).toBeInstanceOf(
      original.constructor,
    )
    expect(decoded.context).toEqual(original.context)
  })

  it("round-trips a query context", () => {
    const original = getChatHistory({
      mode: GetChatHistoryMode.HISTORY_MODE_OLDER,
      beforeId: messageId(42),
      limit: 50,
    })

    expect(
      decodeCoreTransaction(
        structuredClone(encodeCoreTransaction(original)),
      ).context,
    ).toEqual(original.context)
  })

  it("round-trips a read boundary through the worker protocol", () => {
    const original = readMessages({
      peerId: {
        type: {
          oneofKind: "chat",
          chat: { chatId: 42n },
        },
      },
      maxId: messageId("9007199254740997"),
    })

    expect(
      decodeCoreTransaction(
        structuredClone(encodeCoreTransaction(original)),
      ).context,
    ).toEqual(original.context)
  })

  it("round-trips native dialog actions through the worker protocol", () => {
    const peerId = {
      type: {
        oneofKind: "chat" as const,
        chat: { chatId: 42n },
      },
    }
    for (const original of [
      updateDialogOrder({ peerId, pinned: true }),
      updateDialogFollowMode({ peerId, selection: "following" }),
      pinMessage({
        peerId,
        messageId: messageId("9007199254740995"),
        unpin: true,
      }),
    ]) {
      expect(
        decodeCoreTransaction(
          structuredClone(encodeCoreTransaction(original)),
        ).context,
      ).toEqual(original.context)
    }
  })

  it("round-trips reaction identity and its owner-local intent ID", () => {
    const original = addReaction({
      emoji: "👍",
      chatId: chatId("9007199254740993"),
      messageId: messageId("9007199254740995"),
      peerId: {
        type: {
          oneofKind: "chat",
          chat: { chatId: 9007199254740993n },
        },
      },
      intentId: "reaction-intent",
    })

    expect(
      decodeCoreTransaction(
        structuredClone(encodeCoreTransaction(original)),
      ).context,
    ).toEqual(original.context)
  })

  it("refuses local callback-bearing transactions", () => {
    expect(() =>
      encodeCoreTransaction(logOut()),
    ).toThrow(UnsupportedCoreTransaction)
    expect(() =>
      decodeCoreTransaction({
        method: Method.UNSPECIFIED,
        context: {},
      }),
    ).toThrow(UnsupportedCoreTransaction)
  })
})
