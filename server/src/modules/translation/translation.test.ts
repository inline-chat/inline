import { describe, expect, mock, test } from "bun:test"

describe("TranslationModule.translateMessages", () => {
  test("keeps raw translated text when entity conversion fails", async () => {
    const translateTexts = mock()
    const convertEntityOffsets = mock()

    translateTexts.mockReset()
    convertEntityOffsets.mockReset()

    translateTexts.mockResolvedValue([{ messageId: 741, translation: "salam donya" }])
    convertEntityOffsets.mockRejectedValue(new Error("entity conversion failed"))

    const { createTranslationModule } = await import("./translation")
    const translationModule = createTranslationModule({
      translateTexts,
      convertEntityOffsets,
    })
    const result = await translationModule.translateMessages({
      messages: [
        {
          id: 1,
          chatId: 10,
          messageId: 741,
          fromId: 5,
          date: new Date(),
          text: "hello world",
          entities: { entities: [] },
        } as any,
      ],
      language: "fa",
      chat: {
        id: 10,
        title: "Test chat",
        type: "thread",
      } as any,
      actorId: 5,
    })

    expect(result).toHaveLength(1)
    expect(result[0]?.messageId).toBe(741)
    expect(result[0]?.translation).toBe("salam donya")
    expect(result[0]?.entities).toBeNull()
  })
})
