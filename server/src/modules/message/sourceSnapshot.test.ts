import { describe, expect, test } from "bun:test"
import { Message, MessageEntity_Type } from "@inline-chat/protocol/core"
import { messageSourceSnapshot } from "./sourceSnapshot"

describe("public forwarding snapshot tokens", () => {
  test("absent and false sticker flags have the same public snapshot across wire round trips", () => {
    const ordinary = Message.create({ id: 1n, chatId: 10n, fromId: 5n, rev: 0n, message: "ordinary" })
    const expected = messageSourceSnapshot(ordinary)
    for (const isSticker of [undefined, false]) {
      const variant = Message.create({ ...ordinary, isSticker })
      const variants = [variant, Message.fromBinary(Message.toBinary(variant)), Message.fromJson(Message.toJson(variant))]
      for (const roundTrip of variants) {
        expect(roundTrip.isSticker).toBe(isSticker)
        expect(messageSourceSnapshot(roundTrip)).toBe(expected)
      }
    }
    const sticker = Message.create({ ...ordinary, isSticker: true })
    for (const variant of [sticker, Message.fromBinary(Message.toBinary(sticker)), Message.fromJson(Message.toJson(sticker))]) {
      expect(variant.isSticker).toBe(true)
      expect(messageSourceSnapshot(variant)).not.toBe(expected)
    }
  })

  test("ordinary read projections preserve the already-issued live mention token", () => {
    const ordinary = Message.create({ id: 1n, chatId: 6n, fromId: 1000n, rev: 0n,
      message: "@QA Chief For this authorized local QA test, reply with only chief-live-4826. Do not call tools.",
      entities: { entities: [{ type: MessageEntity_Type.MENTION, offset: 0n, length: 9n,
        entity: { oneofKind: "mention", mention: { userId: 1003n } },
      }] },
    })
    const issuedLiveToken = "65485036e1bf41678e6ba55541cd0d25fb2e6f6a68ae7968b35a88066e4a8ac9"
    expect(messageSourceSnapshot(ordinary)).toBe(issuedLiveToken)
    expect(messageSourceSnapshot(Message.create({ ...ordinary, isSticker: false }))).toBe(issuedLiveToken)
  })

  test("canonical flag defaults still bind edit, forwarding and media changes", () => {
    const ordinary = Message.create({ id: 1n, chatId: 10n, fromId: 5n, rev: 0n, message: "ordinary", isSticker: false })
    const expected = messageSourceSnapshot(ordinary)
    for (const changed of [
      Message.create({ ...ordinary, rev: 1n }),
      Message.create({ ...ordinary, message: "edited" }),
      Message.create({ ...ordinary, fwdFrom: { fromId: 6n, fromMessageId: 2n,
        fromPeerId: { type: { oneofKind: "chat", chat: { chatId: 20n } } },
      } }),
      Message.create({ ...ordinary, media: { media: { oneofKind: "nudge", nudge: {} } } }),
    ]) {
      expect(messageSourceSnapshot(changed)).not.toBe(expected)
    }
  })

  test("renewed delivery URLs and viewer decoration preserve the captured token", () => {
    const captured = Message.create({ id: 1n, chatId: 10n, fromId: 5n, rev: 0n, message: "image",
      media: { media: { oneofKind: "photo", photo: { photo: { id: 3n, date: 0n, format: 1, sizes: [{
        type: "d", w: 800, h: 600, size: 100, fileUniqueId: "immutable-file", cdnUrl: "https://cdn.test/a?signature=old",
      }] } } } }, subthread: { chatId: 11n, title: "Existing child", messageCount: 1, hasUnread: false },
    })
    const renewed = Message.fromBinary(Message.toBinary(captured))
    if (renewed.media?.media.oneofKind !== "photo" || !renewed.media.media.photo.photo) throw new Error("missing photo")
    renewed.media.media.photo.photo.sizes[0]!.cdnUrl = "https://cdn.test/a?signature=new"
    renewed.media.media.photo.photo.date = 123n
    renewed.out = true
    renewed.mentioned = true
    renewed.date = 1234n
    renewed.reactions = { reactions: [{ emoji: "❤️", userId: 5n, messageId: 1n, chatId: 10n, date: 1234n }] }
    renewed.subthread!.hasUnread = true
    renewed.subthread!.messageCount = 99
    renewed.agentSession = { agentSessionId: 99n, provider: 1, role: 1, relation: 2 }
    expect(messageSourceSnapshot(renewed)).toBe(messageSourceSnapshot(captured))
    const unavailablePhoto = Message.create({ ...captured, media: { media: { oneofKind: "photo", photo: {} } } })
    expect(messageSourceSnapshot(unavailablePhoto)).not.toBe(messageSourceSnapshot(captured))
    renewed.media.media.photo.photo.id = 4n
    expect(messageSourceSnapshot(renewed)).not.toBe(messageSourceSnapshot(captured))
  })

  test("visible action labels and card content bind the token while callback payloads stay outside it", () => {
    const captured = Message.create({ id: 1n, chatId: 10n, fromId: 5n, rev: 0n,
      actions: { rows: [{ actions: [{ actionId: "approve", text: "Approve", action: {
        oneofKind: "callback", callback: { data: Buffer.from("private callback") },
      } }] }] }, attachments: { attachments: [{ id: 8n, attachment: { oneofKind: "externalTask", externalTask: {
        id: 9n, taskId: "task-9", application: "linear", number: "INL-9", title: "Investigate", status: 2,
        url: "https://linear.test/INL-9", assignedUserId: 0n, date: 0n,
      } } }] },
    })
    const edited = Message.fromBinary(Message.toBinary(captured))
    edited.actions!.rows[0]!.actions[0]!.action = { oneofKind: "callback", callback: { data: Buffer.from("new private callback") } }
    expect(messageSourceSnapshot(edited)).toBe(messageSourceSnapshot(captured))
    edited.actions!.rows[0]!.actions[0]!.text = "Approved"
    expect(messageSourceSnapshot(edited)).not.toBe(messageSourceSnapshot(captured))
    edited.actions!.rows[0]!.actions[0]!.text = "Approve"
    const task = edited.attachments!.attachments[0]!.attachment
    if (task.oneofKind !== "externalTask") throw new Error("missing card")
    task.externalTask.title = "Changed visible title"
    expect(messageSourceSnapshot(edited)).not.toBe(messageSourceSnapshot(captured))
  })
})
