import { describe, expect, test } from "bun:test"
import { MessageEntity_Type } from "@inline-chat/protocol/core"
import { detectHasLink } from "./linkDetection"

const entity = (type: MessageEntity_Type) => ({
  type,
  offset: BigInt(0),
  length: BigInt(1),
  entity: { oneofKind: undefined },
})

describe("detectHasLink", () => {
  test("returns false without entities", () => {
    expect(detectHasLink({ entities: undefined })).toBe(false)
    expect(detectHasLink({ entities: { entities: [] } })).toBe(false)
  })

  test("returns true for url entity", () => {
    expect(
      detectHasLink({
        entities: { entities: [entity(MessageEntity_Type.URL)] },
      }),
    ).toBe(true)
  })

  test("returns true for text_url entity", () => {
    expect(
      detectHasLink({
        entities: {
          entities: [
            {
              ...entity(MessageEntity_Type.TEXT_URL),
              entity: { oneofKind: "textUrl", textUrl: { url: "https://example.com" } },
            },
          ],
        },
      }),
    ).toBe(true)
  })

  test("returns false for non-link entities", () => {
    expect(
      detectHasLink({
        entities: {
          entities: [entity(MessageEntity_Type.MENTION), entity(MessageEntity_Type.BOLD)],
        },
      }),
    ).toBe(false)
  })
})
