import { MessageEntity_Type } from "@inline-chat/protocol/core"
import { describe, expect, it } from "vitest"
import { isInlineMessageEntities } from "./InlineMessageEntities"

describe("isInlineMessageEntities", () => {
  it("accepts bounded protocol entities with UTF-16 ranges", () => {
    expect(
      isInlineMessageEntities(
        {
          entities: [
            {
              type: MessageEntity_Type.MENTION,
              offset: 3n,
              length: 5n,
              entity: {
                oneofKind: "mention",
                mention: { userId: 7n },
              },
            },
          ],
        },
        "hi @Dena",
      ),
    ).toBe(true)
  })

  it("rejects out-of-range and malformed worker input", () => {
    expect(
      isInlineMessageEntities(
        {
          entities: [
            {
              type: MessageEntity_Type.BOLD,
              offset: 0n,
              length: 50n,
              entity: { oneofKind: undefined },
            },
          ],
        },
        "short",
      ),
    ).toBe(false)
    expect(
      isInlineMessageEntities(
        {
          entities: [
            {
              type: MessageEntity_Type.MENTION,
              offset: 0n,
              length: 4n,
              entity: {
                oneofKind: "mention",
                mention: { userId: "7" },
              },
            },
          ],
        },
        "Dena",
      ),
    ).toBe(false)
  })
})
