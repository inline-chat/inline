import { describe, expect, it } from "vitest"
import { chatId, messageId, userId } from "@inline/ids"
import { Db } from "../../database"
import { DbObjectKind } from "../../database/models"
import { createSubthread } from "./create-subthread"
import { forwardMessages } from "./forward-messages"
import { invokeMessageAction } from "./invoke-message-action"

describe("product message transactions", () => {
  it("encodes bounded forward and bot-action requests", () => {
    const forward = forwardMessages({
      fromChatId: chatId(10),
      fromPeerId: { type: { oneofKind: "chat", chat: { chatId: 10n } } },
      toPeerId: { type: { oneofKind: "user", user: { userId: 20n } } },
      messageIds: [messageId(30), messageId(30)],
    })
    expect(forward.input(forward.context)).toMatchObject({
      oneofKind: "forwardMessages",
      forwardMessages: { messageIds: [30n] },
    })
    expect(() => forwardMessages({
      fromChatId: chatId(10),
      messageIds: [],
    })).toThrow(TypeError)

    const action = invokeMessageAction({
      chatId: chatId(10),
      messageId: messageId(30),
      actionId: " approve ",
    })
    expect(action.input(action.context)).toMatchObject({
      oneofKind: "invokeMessageAction",
      invokeMessageAction: { messageId: 30n, actionId: "approve" },
    })
  })

  it("materializes a created reply thread in the authoritative database", () => {
    const db = new Db({ autoHydrate: false, persistence: false })
    const transaction = createSubthread({
      parentChatId: chatId(10),
      parentMessageId: messageId(30),
      participants: [userId(7)],
    })
    const result = {
      oneofKind: "createSubthread" as const,
      createSubthread: {
        chat: {
          id: 90n,
          title: "Reply thread",
          parentChatId: 10n,
          parentMessageId: 30n,
        },
        dialog: {
          chatId: 90n,
          peer: {
            type: { oneofKind: "chat" as const, chat: { chatId: 90n } },
          },
        },
      },
    }
    transaction.apply(result, db)

    expect(transaction.createdChatId(result)).toBe(chatId(90))
    expect(db.get(db.ref(DbObjectKind.Chat, chatId(90)))).toMatchObject({
      parentChatId: chatId(10),
      parentMessageId: messageId(30),
    })
  })
})
