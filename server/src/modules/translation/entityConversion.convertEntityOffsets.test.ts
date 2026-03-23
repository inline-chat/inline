import { afterEach, describe, expect, mock, test } from "bun:test"
import { MessageEntities } from "@inline-chat/protocol/core"

const parseCompletion = mock()

mock.module("@in/server/libs/openAI", () => ({
  openaiClient: {
    chat: {
      completions: {
        parse: parseCompletion,
      },
    },
  },
}))

describe("convertEntityOffsets", () => {
  afterEach(() => {
    parseCompletion.mockReset()
  })

  test("treats null JSON as missing entities", async () => {
    parseCompletion.mockResolvedValue({
      choices: [
        {
          finish_reason: "stop",
          message: {
            content: '{"conversions":[{"messageId":743,"entities":"null"}]}',
            parsed: {
              conversions: [{ messageId: 743, entities: "null" }],
            },
          },
        },
      ],
    })

    const { convertEntityOffsets } = await import("./entityConversion")
    const result = await convertEntityOffsets({
      messages: [
        {
          messageId: 743,
          originalText: "hello",
          translatedText: "salam",
          originalEntities: MessageEntities.create(),
        },
      ],
      actorId: 1,
    })

    expect(result).toEqual([{ messageId: 743, entities: null }])
  })

  test("drops conversion rows with duplicate or unexpected message ids", async () => {
    parseCompletion.mockResolvedValue({
      choices: [
        {
          finish_reason: "stop",
          message: {
            content: `{"conversions":[{"messageId":743,"entities":"null"},{"messageId":743,"entities":"null"},{"messageId":999,"entities":"null"}]}`,
            parsed: {
              conversions: [
                { messageId: 743, entities: "null" },
                { messageId: 743, entities: "null" },
                { messageId: 999, entities: "null" },
              ],
            },
          },
        },
      ],
    })

    const { convertEntityOffsets } = await import("./entityConversion")
    const result = await convertEntityOffsets({
      messages: [
        {
          messageId: 743,
          originalText: "hello",
          translatedText: "salam",
          originalEntities: MessageEntities.create(),
        },
      ],
      actorId: 1,
    })

    expect(result).toEqual([{ messageId: 743, entities: null }])
  })
})
