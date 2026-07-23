import { Update } from "@inline-chat/protocol/core"
import { chatId, messageId, userId } from "@inline/ids"
import { describe, expect, it } from "vitest"
import {
  Db,
  DbObjectKind,
  DbQueryPlanType,
  messageKey,
} from "../../index"
import { applyUpdates } from "../updates"

const targetChatId = chatId(801)
const targetMessageId = messageId(41)
const targetKey = messageKey(targetChatId, targetMessageId)

const externalTaskAttachment = (
  attachmentId: bigint,
  taskRowId: bigint,
  title: string,
) => ({
  id: attachmentId,
  attachment: {
    oneofKind: "externalTask" as const,
    externalTask: {
      id: taskRowId,
      taskId: "ENG-41",
      application: "linear",
      title,
      status: 3,
      assignedUserId: 7n,
      url: "https://linear.app/issue/ENG-41",
      number: "ENG-41",
      date: 1_000n,
    },
  },
})

const previewAttachment = (
  attachmentId: bigint,
  previewId: bigint,
  title: string,
) => ({
  id: attachmentId,
  attachment: {
    oneofKind: "urlPreview" as const,
    urlPreview: {
      id: previewId,
      url: "https://inline.chat",
      title,
    },
  },
})

const attachmentUpdate = (
  attachment: ReturnType<typeof externalTaskAttachment> |
    ReturnType<typeof previewAttachment> | {
      id: bigint
      attachment: { oneofKind: undefined }
    },
  options: { chat?: bigint; message?: bigint; seq?: number } = {},
) =>
  Update.create({
    seq: options.seq,
    update: {
      oneofKind: "messageAttachment",
      messageAttachment: {
        chatId: options.chat ?? 801n,
        messageId: options.message ?? 41n,
        attachment,
      },
    },
  })

const residentDb = () => {
  const db = new Db({ autoHydrate: false })
  db.insert({
    kind: DbObjectKind.Message,
    id: targetKey,
    messageId: targetMessageId,
    chatId: targetChatId,
    fromId: userId(8),
    message: "Keep this text",
    reactions: {
      reactions: [
        {
          emoji: "👍",
          userId: 7n,
          messageId: 41n,
          chatId: 801n,
          date: 1_000n,
        },
      ],
    },
  })
  return db
}

describe("UpdateMessageAttachment", () => {
  it("adds and updates a resident attachment without replacing message state", () => {
    const db = residentDb()
    const added = externalTaskAttachment(70n, 700n, "First title")

    expect(applyUpdates(db, [attachmentUpdate(added)])).toMatchObject({
      applied: 1,
      deferred: 0,
    })
    expect(db.get(db.ref(DbObjectKind.Message, targetKey))).toMatchObject({
      message: "Keep this text",
      reactions: { reactions: [{ emoji: "👍" }] },
      attachments: { attachments: [added] },
    })

    const updated = externalTaskAttachment(71n, 700n, "Updated title")
    applyUpdates(db, [attachmentUpdate(updated)])
    expect(
      db.get(db.ref(DbObjectKind.Message, targetKey))?.attachments?.attachments,
    ).toEqual([updated])
  })

  it("keeps attachment order while replacing and deduplicating an item", () => {
    const db = residentDb()
    const first = previewAttachment(60n, 600n, "First")
    const duplicate = previewAttachment(61n, 600n, "Duplicate")
    const second = previewAttachment(62n, 602n, "Second")
    db.update({
      ...db.get(db.ref(DbObjectKind.Message, targetKey))!,
      attachments: { attachments: [first, duplicate, second] },
    })
    const replacement = previewAttachment(63n, 600n, "Replacement")

    applyUpdates(db, [attachmentUpdate(replacement)])

    expect(
      db.get(db.ref(DbObjectKind.Message, targetKey))?.attachments?.attachments,
    ).toEqual([replacement, second])
  })

  it("deletes by stable attachment ID and the native legacy task-row fallback", () => {
    const db = residentDb()
    const first = externalTaskAttachment(70n, 700n, "First")
    const legacy = externalTaskAttachment(71n, 70n, "Legacy")
    db.update({
      ...db.get(db.ref(DbObjectKind.Message, targetKey))!,
      attachments: { attachments: [first, legacy] },
    })

    applyUpdates(db, [
      attachmentUpdate({ id: 70n, attachment: { oneofKind: undefined } }),
    ])
    expect(
      db.get(db.ref(DbObjectKind.Message, targetKey))?.attachments?.attachments,
    ).toEqual([legacy])

    applyUpdates(db, [
      attachmentUpdate({ id: 70n, attachment: { oneofKind: undefined } }),
    ])

    expect(
      db.get(db.ref(DbObjectKind.Message, targetKey))?.attachments,
    ).toBeUndefined()
  })

  it("retains missing-target and malformed updates losslessly", () => {
    const db = new Db({ autoHydrate: false })
    const missing = attachmentUpdate(
      previewAttachment(60n, 600n, "Later"),
      { seq: 9 },
    )
    const malformed = attachmentUpdate(
      previewAttachment(61n, 601n, "Invalid"),
      { chat: 0n, seq: 10 },
    )

    expect(applyUpdates(db, [missing, malformed])).toMatchObject({
      applied: 0,
      deferred: 2,
    })
    const deferred = db.queryCollection(
      DbQueryPlanType.Objects,
      DbObjectKind.DeferredUpdate,
    )
    expect(deferred).toHaveLength(2)
    expect(deferred.find((item) => item.seq === 9)?.targetKey).toBe(targetKey)
    expect(deferred.find((item) => item.seq === 10)?.targetKey).toBeUndefined()
    expect(Update.fromBinary(deferred[0]!.payload)).toBeDefined()
  })
})
