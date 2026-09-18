import { afterEach, describe, expect, mock, spyOn, test } from "bun:test"
import { Log } from "@in/server/utils/log"
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

  test("keeps malformed provider content out of warning logs and propagated errors", async () => {
    const secret = "synthetic-private-provider-content"
    const warnings = spyOn(Log.prototype, "warn").mockImplementation(() => {})
    const { convertEntityOffsets } = await import("./entityConversion")
    const input = { messages: [{ messageId: 1, originalText: "hello", translatedText: "salam",
      originalEntities: MessageEntities.create() }], actorId: 1 }
    try {
      for (const entities of [JSON.stringify({ unexpected: secret }), `${secret} invalid JSON`]) {
        parseCompletion.mockResolvedValue({ choices: [{ finish_reason: "stop", message: {
          parsed: { conversions: [{ messageId: 1, entities }] }, content: secret,
        } }] })
        expect(await convertEntityOffsets(input)).toEqual([{ messageId: 1, entities: null }])
      }
      expect(warnings).toHaveBeenCalledTimes(2)
      expect(JSON.stringify(warnings.mock.calls)).not.toContain(secret)
      parseCompletion.mockRejectedValue(new Error(secret))
      await expect(convertEntityOffsets(input)).rejects.toThrow("Entity conversion provider request failed")
    } finally { warnings.mockRestore() }
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
