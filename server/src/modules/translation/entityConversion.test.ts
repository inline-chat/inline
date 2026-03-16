import { describe, expect, mock, test } from "bun:test"
import { MessageEntities } from "@inline-chat/protocol/core"

const parseCompletion = mock()
const logError = mock()
const logWarn = mock()

mock.module("@in/server/libs/openAI", () => ({
  openaiClient: {
    chat: {
      completions: {
        parse: parseCompletion,
      },
    },
  },
}))

mock.module("@in/server/utils/log", () => ({
  Log: class {
    error = logError
    warn = logWarn
    info() {}
    debug() {}
    trace() {}
  },
}))

describe("createIndexedText", () => {
  test("indexes basic ASCII by UTF-16 position", async () => {
    const { createIndexedText } = await import("./entityConversion")
    expect(createIndexedText("Hi")).toBe("0H1i")
  })

  test("indexes surrogate pairs using UTF-16 length", async () => {
    const { createIndexedText } = await import("./entityConversion")
    expect(createIndexedText("😀a")).toBe("0😀2a")
  })

  test("indexes emoji with variation selector using UTF-16 length", async () => {
    const { createIndexedText } = await import("./entityConversion")
    expect(createIndexedText("🛍️A")).toBe("0🛍2️3A")
  })
})

describe("convertEntityOffsets", () => {
  test("treats null JSON as missing entities without logging a parser error", async () => {
    parseCompletion.mockReset()
    logError.mockReset()
    logWarn.mockReset()
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
    expect(logError).not.toHaveBeenCalled()
  })
})
