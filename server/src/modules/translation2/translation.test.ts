import { describe, expect, mock, test } from "bun:test"
import { MessageEntity_Type } from "@inline-chat/protocol/core"

describe("Translation2.translateMessages", () => {
  test("translates markdown in one call and parses entities locally", async () => {
    const translateMarkdowns = mock(async (input) => {
      expect(input.messages).toHaveLength(1)
      expect(input.messages[0]?.markdown).toBe("[hello](inline://user/42)")
      return [{ messageId: 741, markdown: "[سلام](inline://user/42)" }]
    })

    const { createTranslationModule } = await import("./translation")
    const translationModule = createTranslationModule({
      translateMarkdowns,
    })

    const result = await translationModule.translateMessages({
      messages: [
        {
          id: 1,
          chatId: 10,
          messageId: 741,
          fromId: 5,
          date: new Date(),
          text: "hello",
          entities: {
            entities: [
              {
                type: MessageEntity_Type.MENTION,
                offset: 0n,
                length: 5n,
                entity: {
                  oneofKind: "mention",
                  mention: { userId: 42n },
                },
              },
            ],
          },
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

    expect(translateMarkdowns).toHaveBeenCalledTimes(1)
    expect(result).toHaveLength(1)
    expect(result[0]?.messageId).toBe(741)
    expect(result[0]?.translation).toBe("سلام")
    expect(result[0]?.entities).toEqual({
      entities: [
        {
          type: MessageEntity_Type.MENTION,
          offset: 0n,
          length: 4n,
          entity: {
            oneofKind: "mention",
            mention: { userId: 42n },
          },
        },
      ],
    })
  })

  test("returns explicit empty entities when translated markdown has no entities", async () => {
    const translateMarkdowns = mock(async () => [{ messageId: 741, markdown: "سلام دنیا" }])

    const { createTranslationModule } = await import("./translation")
    const translationModule = createTranslationModule({
      translateMarkdowns,
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

    expect(result[0]?.translation).toBe("سلام دنیا")
    expect(result[0]?.entities).toEqual({ entities: [] })
  })
})
