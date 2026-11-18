import {
  BlockContent,
  Message as ProtoMessage,
  MessageSubthread_Kind,
  Photo_Format,
  Update,
  type Message as ProtoMessageType,
} from "@inline-chat/protocol/core"
import { chatId, messageId } from "@inline/ids"
import { describe, expect, it } from "vitest"
import { Db } from "../../database"
import { DbObjectKind, messageKey } from "../../database/models"
import { createSqliteMemoryPersistenceStore } from "../../database/sqlite/openers"
import { messageRow } from "../../queries/rows"
import { upsertMessage } from "../transactions/mappers"
import { applyUpdates } from "../updates/apply-updates"

/*
 * Rich message content (`blockContent`, `replyQuote`, `via`, `subthread`) is
 * stored on the message row and survives SQLite, including int64 IDs and
 * bytes inside blocks. Edits and partial snapshots follow InlineKit: an edit
 * replaces block content (and clears it when absent); other snapshots keep
 * it; `via`, `subthread` and `replyQuote` are kept when omitted.
 */

const stripped = new Uint8Array([1, 2, 3, 250])

const blocks = BlockContent.create({
  blocks: [
    { kind: { oneofKind: "paragraph", paragraph: { offset: 0n, length: 5n } } },
    {
      kind: {
        oneofKind: "image",
        image: {
          alt: { offset: 6n, length: 3n },
          state: {
            oneofKind: "ready",
            ready: {
              id: 9_007_199_254_740_993n,
              date: 1_700_000_000n,
              fileUniqueId: "img",
              format: Photo_Format.JPEG,
              sizes: [{ type: "s", w: 40, h: 30, size: 4, bytes: stripped }],
            },
          },
        },
      },
    },
  ],
})

const proto = (extra: Partial<ProtoMessageType> = {}) =>
  ProtoMessage.create({
    id: 41n,
    fromId: 7n,
    chatId: 5n,
    peerId: { type: { oneofKind: "chat", chat: { chatId: 5n } } },
    message: "hello pic",
    out: false,
    date: 1_700_000_100n,
    ...extra,
  })

const rich = proto({
  blockContent: blocks,
  replyQuote: "quoted",
  via: { source: { oneofKind: "botUserId", botUserId: 9_007_199_254_740_995n }, name: "Bot" },
  subthread: {
    chatId: 9_007_199_254_740_997n,
    kind: MessageSubthread_Kind.SUBTHREAD,
    title: "Thread",
    messageCount: 3,
    hasUnread: true,
    recentAuthorUserIds: [7n, 8n],
  },
})

const key = messageKey(chatId(5), messageId(41))

describe("rich message content in the replica", () => {
  it("round-trips through SQLite with int64 IDs and bytes, and maps to row blocks end to end", async () => {
    const store = createSqliteMemoryPersistenceStore()
    const db = new Db({ autoHydrate: false, persistenceStore: store })
    upsertMessage(db, rich)
    await db.flushPersistence()

    const read = await store.collection(DbObjectKind.Message).get(key)
    expect(read?.blockContent).toEqual(blocks)
    expect(read?.replyQuote).toBe("quoted")
    expect(read?.via).toEqual(rich.via)
    expect(read?.subthread).toEqual(rich.subthread)
    const image = read?.blockContent?.blocks[1]?.kind
    expect(image?.oneofKind === "image" && image.image.state.oneofKind === "ready"
      ? image.image.state.ready.sizes[0]?.bytes
      : undefined).toEqual(stripped)

    const row = messageRow(read!, undefined, undefined)
    expect(row.blocks?.map((block) => block.kind)).toEqual(["paragraph", "image"])
    expect(row.replyQuote).toBe("quoted")
    expect(row.via).toBeDefined()
    expect(row.replies).toBeDefined()
  })

  it("an edit replaces block content and clears it when absent, keeping via, subthread and the quote", () => {
    const db = new Db({ autoHydrate: false })
    upsertMessage(db, rich)
    const edit = (message: ProtoMessageType) =>
      Update.create({ seq: 1, date: 1n, update: { oneofKind: "editMessage", editMessage: { message } } })

    applyUpdates(db, [edit(proto({ message: "hello again" }))])
    const edited = db.get(db.ref(DbObjectKind.Message, key))
    expect(edited?.message).toBe("hello again")
    expect(edited?.blockContent).toBeUndefined()
    expect(edited?.via).toEqual(rich.via)
    expect(edited?.subthread).toEqual(rich.subthread)
    expect(edited?.replyQuote).toBe("quoted")

    const replaced = BlockContent.create({
      blocks: [{ kind: { oneofKind: "paragraph", paragraph: { offset: 0n, length: 2n } } }],
    })
    applyUpdates(db, [edit(proto({ blockContent: replaced }))])
    expect(db.get(db.ref(DbObjectKind.Message, key))?.blockContent).toEqual(replaced)
  })

  it("a snapshot without block content (a history page, a replayed new message) keeps the stored blocks", () => {
    const db = new Db({ autoHydrate: false })
    upsertMessage(db, rich)
    applyUpdates(db, [
      Update.create({ seq: 1, date: 1n, update: { oneofKind: "newMessage", newMessage: { message: proto() } } }),
    ])
    expect(db.get(db.ref(DbObjectKind.Message, key))?.blockContent).toEqual(blocks)
  })

  it("an attachment update keeps the rich fields", () => {
    const db = new Db({ autoHydrate: false })
    upsertMessage(db, rich)
    applyUpdates(db, [
      Update.create({
        seq: 2,
        date: 2n,
        update: {
          oneofKind: "messageAttachment",
          messageAttachment: {
            messageId: 41n,
            chatId: 5n,
            peerId: { type: { oneofKind: "chat", chat: { chatId: 5n } } },
            attachment: {
              id: 70n,
              attachment: {
                oneofKind: "urlPreview",
                urlPreview: { id: 71n, url: "https://example.com", title: "Example" },
              },
            },
          },
        },
      }),
    ])
    const message = db.get(db.ref(DbObjectKind.Message, key))
    expect(message?.attachments?.attachments).toHaveLength(1)
    expect(message?.blockContent).toEqual(blocks)
    expect(message?.via).toEqual(rich.via)
  })
})
