import { describe, expect, test } from "bun:test"
import { Message } from "@inline-chat/protocol/core"
import { messageSourceSnapshot } from "./sourceSnapshot"

describe("public forwarding snapshot tokens", () => {
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
