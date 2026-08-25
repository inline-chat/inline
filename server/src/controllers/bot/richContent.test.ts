import { describe, expect, test } from "bun:test"
import {
  BlockDisclosure_Kind,
  BlockList_Kind,
  BlockTable_Alignment,
  MessageEntity_Type,
  Photo_Format,
  type BlockContent,
  type MessageEntities,
} from "@inline-chat/protocol/core"
import { encodeBotEntities } from "./entityCodec"
import { encodeBotRichMessage } from "./richContent"

const none = { oneofKind: undefined } as const

describe("Bot rich content projection", () => {
  test("uses Telegram mention names and UTF-16 ranges for ordinary text", () => {
    const usersById = new Map([[7, { id: 7, is_bot: false, username: "maya" }]])
    const encoded = encodeBotEntities({
      entities: [
        {
          type: MessageEntity_Type.MENTION,
          offset: 6n,
          length: 4n,
          entity: { oneofKind: "mention", mention: { userId: 7n } },
        },
        {
          type: MessageEntity_Type.USERNAME_MENTION,
          offset: 11n,
          length: 5n,
          entity: none,
        },
        {
          type: MessageEntity_Type.GROUP_MENTION,
          offset: 17n,
          length: 6n,
          entity: { oneofKind: "groupMention", groupMention: { groupId: 9n } },
        },
      ],
    }, { usersById })

    expect(encoded).toEqual([
      { type: "text_mention", offset: 6, length: 4, user: usersById.get(7) },
      { type: "mention", offset: 11, length: 5 },
      { type: "group_mention", offset: 17, length: 6, group_id: 9 },
    ])
  })

  test("nests overlapping formatting and stable mentions without references", () => {
    const text = "Hi 👋 Maya"
    const entities: MessageEntities = {
      entities: [
        {
          type: MessageEntity_Type.BOLD,
          offset: 3n,
          length: 7n,
          entity: none,
        },
        {
          type: MessageEntity_Type.MENTION,
          offset: 6n,
          length: 4n,
          entity: { oneofKind: "mention", mention: { userId: 7n } },
        },
      ],
    }
    const rich = encodeBotRichMessage({
      text,
      entities,
      usersById: new Map([[7, { id: 7, is_bot: false, first_name: "Maya" }]]),
      blockContent: {
        blocks: [{
          kind: {
            oneofKind: "paragraph",
            paragraph: { offset: 0n, length: 10n },
          },
        }],
      },
    })

    expect(rich).toEqual({
      blocks: [{
        type: "paragraph",
        text: [
          "Hi ",
          {
            type: "bold",
            text: [
              "👋 ",
              {
                type: "text_mention",
                text: "Maya",
                user: { id: 7, is_bot: false, first_name: "Maya" },
              },
            ],
          },
        ],
      }],
    })
  })

  test("keeps the complete semantic value when formatting splits a URL", () => {
    const rich = encodeBotRichMessage({
      text: "https://inline.chat",
      entities: {
        entities: [
          {
            type: MessageEntity_Type.URL,
            offset: 0n,
            length: 19n,
            entity: none,
          },
          {
            type: MessageEntity_Type.BOLD,
            offset: 8n,
            length: 6n,
            entity: none,
          },
        ],
      },
      blockContent: {
        blocks: [{
          kind: {
            oneofKind: "paragraph",
            paragraph: { offset: 0n, length: 19n },
          },
        }],
      },
    })

    expect(rich).toEqual({
      blocks: [{
        type: "paragraph",
        text: {
          type: "url",
          url: "https://inline.chat",
          text: [
            "https://",
            { type: "bold", text: "inline" },
            ".chat",
          ],
        },
      }],
    })
  })

  test("projects the current structural block vocabulary into one recursive tree", () => {
    const text = "TitleItemSummaryBodyAB"
    const blockContent: BlockContent = {
      blocks: [
        {
          kind: {
            oneofKind: "heading",
            heading: { level: 2, text: { offset: 0n, length: 5n } },
          },
        },
        {
          kind: {
            oneofKind: "list",
            list: {
              kind: BlockList_Kind.ORDERED,
              start: 3n,
              items: [{
                checked: true,
                children: [{
                  kind: {
                    oneofKind: "paragraph",
                    paragraph: { offset: 5n, length: 4n },
                  },
                }],
              }],
            },
          },
        },
        {
          kind: {
            oneofKind: "disclosure",
            disclosure: {
              summary: { offset: 9n, length: 7n },
              kind: BlockDisclosure_Kind.PROGRESS,
              initiallyOpen: true,
              children: [{
                kind: {
                  oneofKind: "paragraph",
                  paragraph: { offset: 16n, length: 4n },
                },
              }],
            },
          },
        },
        {
          kind: {
            oneofKind: "table",
            table: {
              alignments: [BlockTable_Alignment.CENTER, BlockTable_Alignment.RIGHT],
              rows: [{
                cells: [
                  { offset: 20n, length: 1n },
                  { offset: 21n, length: 1n },
                ],
              }],
            },
          },
        },
        {
          kind: {
            oneofKind: "image",
            image: {
              state: {
                oneofKind: "ready",
                ready: {
                  id: 1n,
                  date: 1n,
                  format: Photo_Format.PNG,
                  fileUniqueId: "photo-file",
                  sizes: [{ type: "f", w: 640, h: 480, size: 12_000 }],
                },
              },
            },
          },
        },
      ],
    }

    const rich = encodeBotRichMessage({ text, blockContent })
    expect(rich?.blocks.map((block) => block.type)).toEqual([
      "heading",
      "list",
      "details",
      "table",
      "photo",
    ])
    expect(rich?.blocks[1]).toMatchObject({
      type: "list",
      items: [{ label: "3", value: 3, has_checkbox: true, is_checked: true }],
    })
    expect(rich?.blocks[2]).toMatchObject({
      type: "details",
      summary: "Summary",
      kind: "progress",
      is_open: true,
    })
    expect(rich?.blocks[3]).toMatchObject({
      type: "table",
      cells: [[
        { text: "A", align: "center", is_header: true },
        { text: "B", align: "right", is_header: true },
      ]],
    })
    expect(rich?.blocks[4]).toMatchObject({
      type: "photo",
      file: {
        file_id: "photo-file",
        mime_type: "image/png",
        width: 640,
        height: 480,
      },
      width: 640,
      height: 480,
    })
  })
})
