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
  const originalDebug = process.env["DEBUG"]
  const originalWarn = console.warn

  afterEach(() => {
    parseCompletion.mockReset()
    process.env["DEBUG"] = originalDebug
    console.warn = originalWarn
  })

  test("treats null JSON as missing entities without logging a parser error", async () => {
    process.env["DEBUG"] = "1"

    const warnCalls: unknown[][] = []
    console.warn = ((...args: unknown[]) => {
      warnCalls.push(args)
    }) as typeof console.warn

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
    expect(warnCalls).toEqual([])
  })

  test("warns and drops conversion rows with duplicate or unexpected message ids", async () => {
    process.env["DEBUG"] = "1"

    const warnCalls: unknown[][] = []
    console.warn = ((...args: unknown[]) => {
      warnCalls.push(args)
    }) as typeof console.warn

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
    expect(warnCalls.length).toBeGreaterThan(0)
  })
})
