import { describe, expect, test } from "bun:test"
import { MessageEntity_Type, type MessageEntities } from "@inline-chat/protocol/core"
import { encodeTranslation, encodeUnencryptedTranslation } from "./encodeTranslation"

describe("encodeTranslation", () => {
  test("encodes missing persisted translation entities as an explicit empty entity list", () => {
    const translation = encodeTranslation({
      translation: {
        messageId: 42,
        language: "en",
        translation: null,
        translationIv: null,
        translationTag: null,
        date: new Date(0),
        msgRev: 0,
        entities: null,
      } as any,
    })

    expect(translation.entities).toEqual({ entities: [] })
  })

  test("encodes missing unencrypted translation entities as an explicit empty entity list", () => {
    const translation = encodeUnencryptedTranslation({
      translation: {
        chatId: 1,
        messageId: 42,
        language: "en",
        translation: "hello",
        date: new Date(0),
        msgRev: 0,
        entities: null,
      },
    })

    expect(translation.entities).toEqual({ entities: [] })
  })

  test("preserves provided unencrypted translation entities", () => {
    const entities: MessageEntities = {
      entities: [
        {
          type: MessageEntity_Type.BOLD,
          offset: 0n,
          length: 5n,
          entity: { oneofKind: undefined },
        },
      ],
    }

    const translation = encodeUnencryptedTranslation({
      translation: {
        chatId: 1,
        messageId: 42,
        language: "en",
        translation: "hello",
        date: new Date(0),
        msgRev: 0,
        entities,
      },
    })

    expect(translation.entities).toEqual(entities)
  })
})
