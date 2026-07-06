import { describe, expect, it } from "bun:test"
import { db, schema } from "@in/server/db"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"
import type { DbChat, DbThreadGraphLink, DbUser } from "@in/server/db/schema"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { getBacklinks, getOutlinks, getReferences, getSubthreads } from "./queries"

setupTestLifecycle()

describe("thread graph queries", () => {
  it("lists backlinks and outlinks with related endpoint chats", async () => {
    const user = await testUtils.createUser("graph-list@example.com")
    const source = await createHomeThread("Graph source", user, [user])
    const target = await createHomeThread("Graph target", user, [user])
    const link = await insertGraphLink({
      key: "thread-link:list",
      scopeId: user.id,
      fromChatId: source.id,
      toChatId: target.id,
    })

    const backlinks = await getBacklinks({ chatId: target.id, currentUserId: user.id })
    expect(backlinks.links.map((row) => row.id)).toEqual([link.id])
    expect(backlinks.relatedChats.map((chat) => chat.id)).toEqual([source.id])
    expect(backlinks.nextBeforeId).toBeNull()

    const outlinks = await getOutlinks({ chatId: source.id, currentUserId: user.id })
    expect(outlinks.links.map((row) => row.id)).toEqual([link.id])
    expect(outlinks.relatedChats.map((chat) => chat.id)).toEqual([target.id])
    expect(outlinks.nextBeforeId).toBeNull()
  })

  it("paginates backlinks by graph link id", async () => {
    const user = await testUtils.createUser("graph-page@example.com")
    const target = await createHomeThread("Graph target", user, [user])
    const sources = await Promise.all([
      createHomeThread("Graph source 1", user, [user]),
      createHomeThread("Graph source 2", user, [user]),
      createHomeThread("Graph source 3", user, [user]),
    ])

    const links = []
    for (const [index, source] of sources.entries()) {
      links.push(
        await insertGraphLink({
          key: `thread-link:page:${index}`,
          scopeId: user.id,
          fromChatId: source.id,
          toChatId: target.id,
        }),
      )
    }

    const firstPage = await getBacklinks({ chatId: target.id, currentUserId: user.id, limit: 2 })
    expect(firstPage.links.map((row) => row.id)).toEqual([links[2]!.id, links[1]!.id])
    expect(firstPage.nextBeforeId).toBe(links[1]!.id)

    const secondPage = await getBacklinks({
      chatId: target.id,
      currentUserId: user.id,
      limit: 2,
      beforeId: firstPage.nextBeforeId ?? undefined,
    })
    expect(secondPage.links.map((row) => row.id)).toEqual([links[0]!.id])
    expect(secondPage.nextBeforeId).toBeNull()
  })

  it("includes parent backlinks in references while subthreads remains children", async () => {
    const user = await testUtils.createUser("graph-split@example.com")
    const parent = await createHomeThread("Graph parent", user, [user])
    const source = await createHomeThread("Graph source", user, [user])
    const child = await createHomeThread("Graph child", user, [user])

    const reference = await insertGraphLink({
      key: "thread-link:split",
      kind: "thread_link",
      scopeId: user.id,
      fromChatId: source.id,
      toChatId: parent.id,
    })
    const subthread = await insertGraphLink({
      key: "reply-thread:split",
      kind: "reply_thread",
      scopeId: user.id,
      fromChatId: parent.id,
      toChatId: child.id,
    })
    const childReference = await insertGraphLink({
      key: "thread-link:split:child",
      kind: "thread_link",
      scopeId: user.id,
      fromChatId: source.id,
      toChatId: child.id,
    })

    const references = await getReferences({ chatId: parent.id, currentUserId: user.id })
    expect(references.links.map((row) => row.id)).toEqual([reference.id])
    expect(references.relatedChats.map((chat) => chat.id)).toEqual([source.id])

    const childReferences = await getReferences({ chatId: child.id, currentUserId: user.id })
    expect(childReferences.links.map((row) => row.id)).toEqual([childReference.id, subthread.id])
    expect(childReferences.links.map((row) => row.kind)).toEqual(["thread_link", "reply_thread"])
    expect(childReferences.relatedChats.map((chat) => chat.id)).toEqual([source.id, parent.id])

    const subthreads = await getSubthreads({ chatId: parent.id, currentUserId: user.id })
    expect(subthreads.links.map((row) => row.id)).toEqual([subthread.id])
    expect(subthreads.relatedChats.map((chat) => chat.id)).toEqual([child.id])
  })

  it("filters graph rows whose other endpoint is inaccessible", async () => {
    const viewer = await testUtils.createUser("graph-viewer@example.com")
    const other = await testUtils.createUser("graph-other@example.com")
    const target = await createHomeThread("Graph target", viewer, [viewer])
    const visibleSource = await createHomeThread("Visible source", viewer, [viewer])
    const hiddenSource = await createHomeThread("Hidden source", other, [other])

    const visibleLink = await insertGraphLink({
      key: "thread-link:visible",
      scopeId: viewer.id,
      fromChatId: visibleSource.id,
      toChatId: target.id,
    })
    const hiddenLink = await insertGraphLink({
      key: "thread-link:hidden",
      scopeId: other.id,
      fromChatId: hiddenSource.id,
      toChatId: target.id,
    })

    const result = await getBacklinks({ chatId: target.id, currentUserId: viewer.id })
    expect(result.links.map((row) => row.id)).toEqual([visibleLink.id])
    expect(result.links.some((row) => row.id === hiddenLink.id)).toBe(false)
    expect(result.relatedChats.map((chat) => chat.id)).toEqual([visibleSource.id])
  })

  it("requires access to the requested root chat", async () => {
    const owner = await testUtils.createUser("graph-owner@example.com")
    const outsider = await testUtils.createUser("graph-outsider@example.com")
    const target = await createHomeThread("Graph target", owner, [owner])

    await expect(getBacklinks({ chatId: target.id, currentUserId: outsider.id })).rejects.toMatchObject({
      code: RealtimeRpcError.Code.PEER_ID_INVALID,
    })
  })
})

async function createHomeThread(title: string, owner: DbUser, participants: DbUser[]): Promise<DbChat> {
  const chat = await testUtils.createChat(null, title, "thread", false, owner.id)
  if (!chat) {
    throw new Error(`Failed to create ${title}`)
  }

  for (const participant of participants) {
    await testUtils.addParticipant(chat.id, participant.id)
  }

  return chat
}

async function insertGraphLink(input: {
  key: string
  kind?: "thread_link" | "reply_thread"
  scopeId: number
  fromChatId: number
  toChatId: number
}): Promise<DbThreadGraphLink> {
  const [row] = await db
    .insert(schema.threadGraphLinks)
    .values({
      dedupeKey: input.key,
      kind: input.kind ?? "thread_link",
      scopeType: "user",
      scopeId: input.scopeId,
      fromChatId: input.fromChatId,
      toChatId: input.toChatId,
      deletedAt: null,
    })
    .returning()

  if (!row) {
    throw new Error(`Failed to insert graph link ${input.key}`)
  }

  return row
}
