import { describe, expect, it } from "vitest"
import { chatId, messageId, userId } from "@inline/ids"
import {
  decodeInlineModel,
  encodeInlineModel,
  InlineModelCodecError,
} from "../model-codec"
import {
  DbObjectKind,
  messageKey,
  type DeferredUpdate,
  type Message,
} from "../models"

describe("Inline model persistence codec", () => {
  it("round-trips exact protocol integers and byte payloads", () => {
    const message: Message = {
      kind: DbObjectKind.Message,
      id: messageKey(chatId("9223372036854775806"), messageId(-7)),
      chatId: chatId("9223372036854775806"),
      messageId: messageId(-7),
      fromId: userId("9223372036854775805"),
      message: "Exact",
      randomId: 9223372036854775807n,
      groupedId: -9223372036854775808n,
      rev: 42n,
      reactionIntents: [
        {
          id: "local-only",
          emoji: "👍",
          userId: userId(1),
          action: "add",
        },
      ],
    }

    expect(
      decodeInlineModel(encodeInlineModel(message)),
    ).toEqual({
      ...message,
      reactionIntents: undefined,
    })

    const deferred: DeferredUpdate = {
      kind: DbObjectKind.DeferredUpdate,
      id: "chat:10:1",
      bucketId: "chat:10",
      payloadType: "Update",
      updateType: "messageAttachment",
      payload: new Uint8Array([0, 1, 2, 127, 255]),
    }
    expect(
      decodeInlineModel(encodeInlineModel(deferred)),
    ).toEqual(deferred)
  })

  it("rejects malformed and unversioned payloads", () => {
    expect(() => decodeInlineModel(new Uint8Array([1, 2, 3]))).toThrow(
      InlineModelCodecError,
    )
  })
})
