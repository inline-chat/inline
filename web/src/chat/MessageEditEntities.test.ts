import { MessageEntity_Type } from "@inline-chat/protocol/core"
import { describe, expect, it } from "vitest"
import { transformEditedMessageEntities } from "./MessageEditEntities"

const plainEntity = (
  type: MessageEntity_Type,
  offset: bigint,
  length: bigint,
) => ({
  type,
  offset,
  length,
  entity: { oneofKind: undefined } as const,
})

describe("transformEditedMessageEntities", () => {
  it("shifts intact formatting and semantic ranges after inserted text", () => {
    const result = transformEditedMessageEntities(
      "Hello @Dena",
      "Really Hello @Dena",
      {
        entities: [
          plainEntity(MessageEntity_Type.BOLD, 0n, 5n),
          {
            type: MessageEntity_Type.MENTION,
            offset: 6n,
            length: 5n,
            entity: {
              oneofKind: "mention",
              mention: { userId: 7n },
            },
          },
        ],
      },
    )

    expect(result?.entities).toMatchObject([
      { type: MessageEntity_Type.BOLD, offset: 7n, length: 5n },
      { type: MessageEntity_Type.MENTION, offset: 13n, length: 5n },
    ])
  })

  it("expands formatting across an edit but drops an edited semantic label", () => {
    const result = transformEditedMessageEntities(
      "Say Dena now",
      "Say Diana now",
      {
        entities: [
          plainEntity(MessageEntity_Type.ITALIC, 0n, 12n),
          {
            type: MessageEntity_Type.MENTION,
            offset: 4n,
            length: 4n,
            entity: {
              oneofKind: "mention",
              mention: { userId: 7n },
            },
          },
        ],
      },
    )

    expect(result?.entities).toEqual([
      plainEntity(MessageEntity_Type.ITALIC, 0n, 13n),
    ])
  })

  it("does not create entity boundaries inside a UTF-16 surrogate pair", () => {
    const result = transformEditedMessageEntities(
      "Bold 😀 text",
      "Bold 😃 text",
      {
        entities: [plainEntity(MessageEntity_Type.BOLD, 0n, 12n)],
      },
    )

    expect(result?.entities).toEqual([
      plainEntity(MessageEntity_Type.BOLD, 0n, 12n),
    ])
  })
})
