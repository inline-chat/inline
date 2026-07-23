import { createEditor } from "lexical"
import { MessageEntity_Type } from "@inline-chat/protocol/core"
import { describe, expect, it } from "vitest"
import { InlineMentionNode } from "./InlineMentionNode"
import {
  $setInlineComposeDocument,
  inlineComposeDocument,
} from "./InlineComposeDocument"

describe("InlineComposeDocument", () => {
  it("round-trips protocol formatting and mention entities without Lexical state leakage", () => {
    const editor = createEditor({ nodes: [InlineMentionNode] })
    editor.update(
      () => {
        $setInlineComposeDocument({
          text: "Hi @Dena\nInline",
          entities: {
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
              {
                type: MessageEntity_Type.BOLD,
                offset: 3n,
                length: 5n,
                entity: { oneofKind: undefined },
              },
              {
                type: MessageEntity_Type.ITALIC,
                offset: 9n,
                length: 6n,
                entity: { oneofKind: undefined },
              },
            ],
          },
        })
      },
      { discrete: true },
    )

    expect(inlineComposeDocument(editor.getEditorState())).toEqual({
      text: "Hi @Dena\nInline",
      entities: {
        entities: [
          {
            type: MessageEntity_Type.BOLD,
            offset: 3n,
            length: 5n,
            entity: { oneofKind: undefined },
          },
          {
            type: MessageEntity_Type.MENTION,
            offset: 3n,
            length: 5n,
            entity: {
              oneofKind: "mention",
              mention: { userId: 7n },
            },
          },
          {
            type: MessageEntity_Type.ITALIC,
            offset: 9n,
            length: 6n,
            entity: { oneofKind: undefined },
          },
        ],
      },
    })
  })
})
