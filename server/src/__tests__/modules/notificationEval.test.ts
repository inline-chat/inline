import { describe, expect, test } from "bun:test"
import { batchEvaluate } from "@in/server/modules/notifications/eval"

describe("notification eval", () => {
  test("zen AI checker is a no-op", async () => {
    const result = await batchEvaluate({
      chatId: 1,
      message: {
        id: 1,
        text: "urgent",
        entities: null,
        message: {
          fromId: 1,
        },
      },
      participantSettings: [
        {
          userId: 2,
          settings: null,
        },
      ],
    })

    expect(result.notifyUserIds).toEqual([])
  })
})
