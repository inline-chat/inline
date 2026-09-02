import { describe, expect, test } from "bun:test"
import { and, eq } from "drizzle-orm"
import { MessageEntity_Type as T, type InputPeer } from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import { dialogs, members, messages, spaces } from "@in/server/db/schema"
import { MessageModel } from "@in/server/db/models/messages"
import { sendMessage } from "@in/server/functions/messages.sendMessage"
import { editMessage } from "@in/server/functions/messages.editMessage"
import { addChatParticipant } from "@in/server/functions/messages.addChatParticipant"
import { createUserGroup } from "@in/server/modules/userGroups"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { setupTestLifecycle, testUtils } from "../setup"

let sequence = 0
const run = Date.now()
const user = (label: string) => testUtils.createUser(`group-md-${label}-${run}-${sequence++}@example.com`)

async function fixture(isPublic = false) {
  const owner = await user("owner"), member = await user("member")
  const space = await testUtils.createSpace("Group markdown")
  if (!space) throw new Error("Missing test space")
  if (isPublic) await db.update(spaces).set({ isPublic: true }).where(eq(spaces.id, space.id))
  await db.insert(members).values([
    { spaceId: space.id, userId: owner.id, role: "owner" },
    { spaceId: space.id, userId: member.id, role: "member" },
  ])
  const context = testUtils.functionContext({ userId: owner.id, sessionId: 1 })
  const { group } = await createUserGroup({ spaceId: space.id, name: "Eng", userIds: [member.id] }, context)
  const chat = await testUtils.createChat(space.id, "Group markdown", "thread", isPublic, owner.id)
  if (!chat) throw new Error("Missing test chat")
  if (!isPublic) {
    await testUtils.addParticipant(chat.id, owner.id)
    await addChatParticipant({ chatId: chat.id, groupId: Number(group.id) }, context)
  }
  const peer: InputPeer = { type: { oneofKind: "chat", chat: { chatId: BigInt(chat.id) } } }
  return { owner, member, space, group, chat, peer, context }
}

describe("group mention Markdown at message boundaries", () => {
  setupTestLifecycle()

  test("authorized Markdown sends retain a group entity and existing recipient side effects", async () => {
    const value = await fixture()
    await sendMessage({ peerId: value.peer, message: `hello [@eng](inline://group/${value.group.id})`, parseMarkdown: true }, value.context)
    const message = await MessageModel.getMessage(1, value.chat.id)
    expect(message?.text).toBe("hello @eng")
    expect(message?.entities?.entities).toEqual([{ type: T.GROUP_MENTION, offset: 6n, length: 4n,
      entity: { oneofKind: "groupMention", groupMention: { groupId: value.group.id } } }])
    const [dialog] = await db.select().from(dialogs).where(and(eq(dialogs.chatId, value.chat.id), eq(dialogs.userId, value.member.id)))
    expect(dialog?.open).toBe(true)
    expect(dialog?.chatListHidden).toBeNull()
  })

  test("a group from another space is rejected before any message is persisted", async () => {
    const value = await fixture(), other = await fixture()
    await expect(sendMessage({ peerId: value.peer, message: `[team](inline://group/${other.group.id})`, parseMarkdown: true }, value.context))
      .rejects.toMatchObject({ code: RealtimeRpcError.Code.PEER_ID_INVALID })
    expect(await db.select({ id: messages.globalId }).from(messages).where(eq(messages.chatId, value.chat.id))).toHaveLength(0)
  })

  test("wire-valid group IDs beyond the database range fail as invalid peers", async () => {
    const value = await fixture()
    for (const id of [2_147_483_648n, 9_223_372_036_854_775_807n]) {
      await expect(sendMessage({ peerId: value.peer, message: `[team](inline://group/${id})`, parseMarkdown: true }, value.context))
        .rejects.toMatchObject({ code: RealtimeRpcError.Code.PEER_ID_INVALID })
    }
    expect(await db.select({ id: messages.globalId }).from(messages).where(eq(messages.chatId, value.chat.id))).toHaveLength(0)
  })

  test("public-space members cannot mention a group they cannot see", async () => {
    const value = await fixture(true), outsider = await user("outside-group")
    await db.insert(members).values({ spaceId: value.space.id, userId: outsider.id, role: "member" })
    await expect(sendMessage({ peerId: value.peer, message: `[team](inline://group/${value.group.id})`, parseMarkdown: true },
      testUtils.functionContext({ userId: outsider.id, sessionId: 1 })))
      .rejects.toMatchObject({ code: RealtimeRpcError.Code.PEER_ID_INVALID })
    expect(await db.select({ id: messages.globalId }).from(messages).where(eq(messages.chatId, value.chat.id))).toHaveLength(0)
  })

  test("edits validate group scope and leave the prior message unchanged on rejection", async () => {
    const value = await fixture(), other = await fixture()
    await sendMessage({ peerId: value.peer, message: "initial" }, value.context)
    await editMessage({ peer: value.peer, messageId: 1n, text: `[team](inline://group/${value.group.id})`, parseMarkdown: true }, value.context)
    const before = await MessageModel.getMessage(1, value.chat.id)
    expect(before?.entities?.entities[0]).toMatchObject({ type: T.GROUP_MENTION,
      entity: { oneofKind: "groupMention", groupMention: { groupId: value.group.id } } })
    await expect(editMessage({ peer: value.peer, messageId: 1n, text: `[other](inline://group/${other.group.id})`, parseMarkdown: true }, value.context))
      .rejects.toMatchObject({ code: RealtimeRpcError.Code.PEER_ID_INVALID })
    const after = await MessageModel.getMessage(1, value.chat.id)
    expect(after?.text).toBe(before?.text)
    expect(after?.entities).toEqual(before?.entities)
    expect(after?.rev).toBe(before?.rev)
  })

  test("explicit group edits in a DM use the same scope guard", async () => {
    const value = await fixture()
    const chat = await testUtils.createPrivateChat(value.owner, value.owner)
    if (!chat) throw new Error("Missing test DM")
    const peer: InputPeer = { type: { oneofKind: "chat", chat: { chatId: BigInt(chat.id) } } }
    await sendMessage({ peerId: peer, message: "initial" }, value.context)
    await expect(editMessage({ peer, messageId: 1n, text: "team", entities: { entities: [{
      type: T.GROUP_MENTION, offset: 0n, length: 4n,
      entity: { oneofKind: "groupMention", groupMention: { groupId: value.group.id } },
    }] } }, value.context)).rejects.toMatchObject({ code: RealtimeRpcError.Code.PEER_ID_INVALID })
    expect((await MessageModel.getMessage(1, chat.id))?.text).toBe("initial")
  })
})
