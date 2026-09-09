import { describe, test, expect } from "bun:test"
import {
  GET_UPDATES_COMPATIBILITY_PAGE_TARGET_BYTES,
  getUpdates,
  replayRequiresAuthoritativeRepair,
} from "@in/server/functions/updates.getUpdates"
import { addChatParticipant } from "@in/server/functions/messages.addChatParticipant"
import { createUserGroup, updateUserGroup } from "@in/server/modules/userGroups"
import { testUtils, setupTestLifecycle } from "../setup"
import { db } from "../../db"
import { updates, UpdateBucket } from "../../db/schema/updates"
import {
  DialogNotificationSettings_Mode,
  GetUpdatesResult as GetUpdatesResultMessage,
  GetUpdatesResult_ResultType,
  RealtimeV3Response,
  type GetUpdatesInput,
  InputPeer,
  Member_Role,
  SyncSkippedSequence_Reason,
} from "@inline-chat/protocol/core"
import {
  MAX_PACKET_BYTES,
  decodeAbridgedPacket,
  decodeInlineApplicationObject,
  decodeRpcResult,
  decryptRecord,
  encodeAbridgedPacket,
  encodeInlineResult,
  encodeRpcResult,
  encryptRecord,
} from "@inline-chat/protocol/secure"
import type { ServerUpdate } from "@in/server/protocol/server"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { UpdatesModel } from "@in/server/db/models/updates"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { UserSettingsNotificationsMode } from "@in/server/db/models/userSettings/types"
import { chats, chatParticipantGroups, chatParticipants, dialogs, members, messages, spaces, userGroupMembers, userGroups, users as usersTable } from "@in/server/db/schema"
import { handler as readMessages } from "@in/server/methods/readMessages"
import { and, desc, eq } from "drizzle-orm"

const insertServerUpdate = async (params: {
  bucket: UpdateBucket
  entityId: number
  seq: number
  payload: ServerUpdate["update"]
}) => {
  const now = new Date()
  const serverUpdate: ServerUpdate = {
    seq: params.seq,
    date: encodeDateStrict(now),
    update: params.payload,
  }
  const record = UpdatesModel.build(serverUpdate)
  await db.insert(updates).values({
    bucket: params.bucket,
    entityId: params.entityId,
    seq: params.seq,
    payload: record.encrypted,
    date: now,
  })
}

const transportTestAuthKey = new Uint8Array(256)
const transportTestMessageSeconds = 1_000_000
const transportTestMessageId = (BigInt(transportTestMessageSeconds) << 32n) | 1n

const realtimeV3WebSocketFrame = (result: Awaited<ReturnType<typeof getUpdates>>): Uint8Array => {
  const applicationPayload = RealtimeV3Response.toBinary({
    body: {
      oneofKind: "rpcResult",
      rpcResult: {
        reqMsgId: 1n,
        result: { oneofKind: "getUpdates", getUpdates: result },
      },
    },
  })
  const body = encodeRpcResult(1n, encodeInlineResult(applicationPayload))
  const paddingLength = 12 + ((16 - ((32 + body.length + 12) % 16)) % 16)
  const record = encryptRecord(transportTestAuthKey, "server-to-client", {
    serverSalt: 1n,
    sessionId: 2n,
    messageId: transportTestMessageId,
    sequenceNumber: 1,
    body,
  }, new Uint8Array(paddingLength))
  return encodeAbridgedPacket(record)
}

const decodeGetUpdatesFrame = (frame: Uint8Array) => {
  const fields = decryptRecord(decodeAbridgedPacket(frame), transportTestAuthKey, {
    direction: "server-to-client",
    sessionId: 2n,
    validServerSalts: new Set([1n]),
    nowSeconds: transportTestMessageSeconds,
  })
  const rpcResult = decodeRpcResult(fields.body)
  const application = decodeInlineApplicationObject(rpcResult.result)
  if (application.kind !== "result") throw new Error("Expected Inline application result")
  const response = RealtimeV3Response.fromBinary(application.payload)
  if (response.body.oneofKind !== "rpcResult" ||
      response.body.rpcResult.result.oneofKind !== "getUpdates") {
    throw new Error("Expected getUpdates RPC result")
  }
  return response.body.rpcResult.result.getUpdates
}

describe("getUpdates", () => {
  setupTestLifecycle()

  test("uses an exclusive 10,000-update authoritative-repair boundary", () => {
    expect(replayRequiresAuthoritativeRepair(0, 9_999)).toBe(false)
    expect(replayRequiresAuthoritativeRepair(0, 10_000)).toBe(false)
    expect(replayRequiresAuthoritativeRepair(0, 10_001)).toBe(true)
    expect(replayRequiresAuthoritativeRepair(50, 10_050)).toBe(false)
    expect(replayRequiresAuthoritativeRepair(50, 10_051)).toBe(true)
  })

  test("returns TOO_LONG with correct seq when gap is too large", async () => {
    // 1. Setup User and Chat
    const { users, space } = await testUtils.createSpaceWithMembers("Test Space", ["user@example.com"])
    const user = users[0]
    const chat = await testUtils.createChat(space.id, "Test Chat", "thread")
    if (!chat) throw new Error("Chat creation failed")

    // The payload is intentionally opaque because TOO_LONG is decided before inflation.
    const dummyPayload = Buffer.from([1, 2, 3])
    await db.insert(updates).values({
      bucket: UpdateBucket.Chat,
      entityId: chat.id,
      seq: 10_001,
      payload: dummyPayload,
    })

    const inputPeer: InputPeer = {
      type: {
        oneofKind: "chat",
        chat: { chatId: BigInt(chat.id) }
      }
    }
    
    const result = await getUpdates({
      bucket: {
        type: {
          oneofKind: "chat",
          chat: { peerId: inputPeer }
        }
      },
      startSeq: 0n,
      seqEnd: 0n,
      totalLimit: 1,
      limit: 0,
    }, { currentUserId: user.id } as any)

    // 4. Verify result
    expect(result.resultType).toBe(GetUpdatesResult_ResultType.TOO_LONG)
    expect(Number(result.seq)).toBe(10_001)
  })

  test("respects seqEnd for sliced getUpdates", async () => {
    const { users } = await testUtils.createSpaceWithMembers("SeqEnd Slice", ["seqend@example.com"])
    const user = users[0]
    if (!user) throw new Error("User creation failed")

    for (let seq = 1; seq <= 5; seq += 1) {
      await insertServerUpdate({
        bucket: UpdateBucket.User,
        entityId: user.id,
        seq,
        payload: {
          oneofKind: "userChatParticipantDelete",
          userChatParticipantDelete: {
            chatId: BigInt(seq),
          },
        },
      })
    }

    const result = await getUpdates({
      bucket: { type: { oneofKind: "user", user: {} } },
      startSeq: 0n,
      seqEnd: 3n,
      totalLimit: 1000,
      limit: 0,
    }, { currentUserId: user.id } as any)

    expect(Number(result.seq)).toBe(3)
    expect(result.final).toBe(true)
    expect(result.resultType).toBe(GetUpdatesResult_ResultType.SLICE)
    expect(result.updates.length).toBe(3)
  })

  test("uses 100 as the default page size", async () => {
    const { users } = await testUtils.createSpaceWithMembers("Page Limit", ["page-limit@example.com"])
    const user = users[0]
    if (!user) throw new Error("User creation failed")

    for (let seq = 1; seq <= 105; seq += 1) {
      await insertServerUpdate({
        bucket: UpdateBucket.User,
        entityId: user.id,
        seq,
        payload: {
          oneofKind: "userChatParticipantDelete",
          userChatParticipantDelete: {
            chatId: BigInt(seq),
          },
        },
      })
    }

    const result = await getUpdates({
      bucket: { type: { oneofKind: "user", user: {} } },
      startSeq: 0n,
      seqEnd: 0n,
      totalLimit: 1,
      limit: 0,
    }, { currentUserId: user.id } as any)

    expect(Number(result.seq)).toBe(100)
    expect(result.final).toBe(false)
    expect(result.resultType).toBe(GetUpdatesResult_ResultType.SLICE)
    expect(result.updates.length).toBe(100)

    const capped = await getUpdates({
      bucket: { type: { oneofKind: "user", user: {} } },
      startSeq: 0n,
      seqEnd: 0n,
      totalLimit: 1,
      limit: 500,
    }, { currentUserId: user.id } as any)

    expect(capped.seq).toBe(100n)
    expect(capped.final).toBe(false)
    expect(capped.updates).toHaveLength(100)
  })

  test("byte-slices a large contiguous catch-up page without losing sequence progress", async () => {
    const { users, space } = await testUtils.createSpaceWithMembers("Byte-Bounded Catch-Up", [
      "byte-page-early-sender@example.com",
      "byte-page-late-sender@example.com",
      "byte-page-viewer@example.com",
    ])
    const earlySender = users[0]
    const lateSender = users[1]
    const viewer = users[2]
    if (!earlySender || !lateSender || !viewer || !space) throw new Error("Fixture creation failed")

    const chat = await testUtils.createChat(space.id, "Byte-Bounded Thread", "thread", true)
    if (!chat) throw new Error("Chat creation failed")
    await testUtils.addParticipant(chat.id, earlySender.id)
    await testUtils.addParticipant(chat.id, lateSender.id)
    await testUtils.addParticipant(chat.id, viewer.id)

    const expectedMessages = new Map<number, {
      chatId: bigint
      fromId: bigint
      id: bigint
      message: string
      out: boolean
    }>()
    for (let seq = 1; seq <= 16; seq += 1) {
      const sender = seq <= 8 ? earlySender : lateSender
      const message = `${seq}:${"x".repeat(80_000)}`
      expectedMessages.set(seq, {
        chatId: BigInt(chat.id),
        fromId: BigInt(sender.id),
        id: BigInt(seq),
        message,
        out: false,
      })
      await db.insert(messages).values({
        chatId: chat.id,
        messageId: seq,
        fromId: sender.id,
        text: message,
      })
      await insertServerUpdate({
        bucket: UpdateBucket.Chat,
        entityId: chat.id,
        seq,
        payload: {
          oneofKind: "newMessage",
          newMessage: { chatId: BigInt(chat.id), msgId: BigInt(seq) },
        },
      })
    }

    const bucket: GetUpdatesInput["bucket"] = {
      type: {
        oneofKind: "chat",
        chat: {
          peerId: { type: { oneofKind: "chat", chat: { chatId: BigInt(chat.id) } } },
        },
      },
    }
    const deliveredSequences: number[] = []
    let cursor = 0
    let final = false
    let pages = 0

    while (!final && pages < 10) {
      const page = await getUpdates({
        bucket,
        startSeq: BigInt(cursor),
        seqEnd: 0n,
        totalLimit: 1000,
        limit: 100,
      }, { currentUserId: viewer.id } as any)
      expect(GetUpdatesResultMessage.toBinary(page).length)
        .toBeLessThanOrEqual(GET_UPDATES_COMPATIBILITY_PAGE_TARGET_BYTES)
      const frame = realtimeV3WebSocketFrame(page)
      expect(frame.length).toBeLessThanOrEqual(1_048_576)
      const decodedPage = decodeGetUpdatesFrame(frame)
      expect(decodedPage.seq).toBe(page.seq)
      expect(decodedPage.updates.map((update) => update.seq))
        .toEqual(page.updates.map((update) => update.seq))
      expect(decodedPage.sidecars?.chats.map((sidecar) => Number(sidecar.id))).toContain(chat.id)
      const expectedSenderIds = new Set<bigint>()
      for (const update of decodedPage.updates) {
        const seq = Number(update.seq)
        const expected = expectedMessages.get(seq)
        expect(expected).toBeDefined()
        expect(update.update.oneofKind).toBe("newMessage")
        if (!expected || update.update.oneofKind !== "newMessage") {
          throw new Error(`Missing expected message for sequence ${seq}`)
        }
        const message = update.update.newMessage.message
        expect(message).toBeDefined()
        if (!message) throw new Error(`Missing decoded message for sequence ${seq}`)
        expect({
          chatId: message.chatId,
          fromId: message.fromId,
          id: message.id,
          message: message.message,
          out: message.out,
        }).toEqual(expected)
        expect(message.peerId?.type.oneofKind).toBe("chat")
        if (message.peerId?.type.oneofKind === "chat") {
          expect(message.peerId.type.chat.chatId).toBe(BigInt(chat.id))
        }
        expectedSenderIds.add(expected.fromId)
      }
      const sortIds = (left: bigint, right: bigint) => Number(left - right)
      const sidecarUserIds = decodedPage.sidecars?.users.map((user) => user.id).sort(sortIds) ?? []
      expect(sidecarUserIds).toEqual(Array.from(expectedSenderIds).sort(sortIds))
      for (const senderId of [BigInt(earlySender.id), BigInt(lateSender.id)]) {
        expect(sidecarUserIds.includes(senderId)).toBe(expectedSenderIds.has(senderId))
      }
      expect(Number(page.seq)).toBeGreaterThan(cursor)
      deliveredSequences.push(...decodedPage.updates.map((update) => Number(update.seq)))
      cursor = Number(page.seq)
      final = page.final === true
      pages += 1
    }

    expect(final).toBe(true)
    expect(pages).toBeGreaterThan(1)
    expect(cursor).toBe(16)
    expect(deliveredSequences).toEqual(Array.from({ length: 16 }, (_, index) => index + 1))
  })

  test("byte-slices mixed delivered and skipped user sequences without losing either", async () => {
    const user = await testUtils.createUser("byte-page-mixed-skips@example.com")
    if (!user) throw new Error("Fixture creation failed")

    const expectedBios = new Map<number, string>()
    for (let seq = 1; seq <= 100; seq += 1) {
      if (seq % 10 === 0) {
        await insertServerUpdate({
          bucket: UpdateBucket.User,
          entityId: user.id,
          seq,
          payload: { oneofKind: undefined },
        })
        continue
      }

      // Deliberately large replay envelopes force a byte boundary while the
      // alternating opaque records exercise the independent skip accounting.
      const bio = `${seq}:${"b".repeat(18_000)}`
      expectedBios.set(seq, bio)
      await insertServerUpdate({
        bucket: UpdateBucket.User,
        entityId: user.id,
        seq,
        payload: {
          oneofKind: "updatedUser",
          updatedUser: {
            user: {
              id: BigInt(100_000 + seq),
              firstName: `User ${seq}`,
              bio,
            },
          },
        },
      })
    }

    const deliveredSequences: number[] = []
    const skippedSequences: number[] = []
    let cursor = 0
    let final = false
    let pages = 0

    while (!final && pages < 10) {
      const page = await getUpdates({
        bucket: { type: { oneofKind: "user", user: {} } },
        startSeq: BigInt(cursor),
        seqEnd: 0n,
        totalLimit: 1000,
        limit: 100,
      }, { currentUserId: user.id } as any)
      expect(GetUpdatesResultMessage.toBinary(page).length)
        .toBeLessThanOrEqual(GET_UPDATES_COMPATIBILITY_PAGE_TARGET_BYTES)
      const decodedPage = decodeGetUpdatesFrame(realtimeV3WebSocketFrame(page))
      expect(decodedPage.seq).toBe(page.seq)

      for (const update of decodedPage.updates) {
        const seq = Number(update.seq)
        const expectedBio = expectedBios.get(seq)
        expect(expectedBio).toBeDefined()
        expect(update.update.oneofKind).toBe("updatedUser")
        if (!expectedBio || update.update.oneofKind !== "updatedUser") {
          throw new Error(`Missing expected user update for sequence ${seq}`)
        }
        expect(update.update.updatedUser.user).toMatchObject({
          id: BigInt(100_000 + seq),
          firstName: `User ${seq}`,
          bio: expectedBio,
        })
        deliveredSequences.push(seq)
      }

      const pageSkippedSequences = decodedPage.skippedSequences.map((skipped) => {
        expect(skipped.reason).toBe(SyncSkippedSequence_Reason.IRRELEVANT_TO_BUCKET)
        return Number(skipped.seq)
      })
      skippedSequences.push(...pageSkippedSequences)
      const accountedSequences = [
        ...decodedPage.updates.map((update) => Number(update.seq)),
        ...pageSkippedSequences,
      ].sort((left, right) => left - right)
      expect(accountedSequences).toEqual(
        Array.from({ length: Number(page.seq) - cursor }, (_, index) => cursor + index + 1),
      )
      expect(Number(page.seq)).toBeGreaterThan(cursor)
      cursor = Number(page.seq)
      final = page.final === true
      pages += 1
    }

    expect(final).toBe(true)
    expect(pages).toBeGreaterThan(1)
    expect(cursor).toBe(100)
    expect(deliveredSequences).toEqual(
      Array.from({ length: 100 }, (_, index) => index + 1).filter((seq) => seq % 10 !== 0),
    )
    expect(skippedSequences).toEqual(Array.from({ length: 10 }, (_, index) => (index + 1) * 10))
  })

  test("returns one indivisible update intact above the compatibility byte target", async () => {
    const { users, space } = await testUtils.createSpaceWithMembers("Single Oversized Catch-Up", [
      "single-oversized@example.com",
    ])
    const user = users[0]
    if (!user || !space) throw new Error("Fixture creation failed")

    const chat = await testUtils.createChat(space.id, "Single Oversized Thread", "thread", true)
    if (!chat) throw new Error("Chat creation failed")
    const expectedMessage = "x".repeat(GET_UPDATES_COMPATIBILITY_PAGE_TARGET_BYTES + 50_000)
    await db.insert(messages).values({
      chatId: chat.id,
      messageId: 1,
      fromId: user.id,
      text: expectedMessage,
    })
    await insertServerUpdate({
      bucket: UpdateBucket.Chat,
      entityId: chat.id,
      seq: 1,
      payload: {
        oneofKind: "newMessage",
        newMessage: { chatId: BigInt(chat.id), msgId: 1n },
      },
    })

    const result = await getUpdates({
      bucket: {
        type: {
          oneofKind: "chat",
          chat: {
            peerId: { type: { oneofKind: "chat", chat: { chatId: BigInt(chat.id) } } },
          },
        },
      },
      startSeq: 0n,
      seqEnd: 0n,
      totalLimit: 1000,
      limit: 100,
    }, { currentUserId: user.id } as any)

    expect(result.resultType).toBe(GetUpdatesResult_ResultType.SLICE)
    expect(result.seq).toBe(1n)
    expect(result.final).toBe(true)
    expect(result.updates).toHaveLength(1)
    expect(result.updates[0]?.seq).toBe(1)
    expect(GetUpdatesResultMessage.toBinary(result).length)
      .toBeGreaterThan(GET_UPDATES_COMPATIBILITY_PAGE_TARGET_BYTES)
    const frame = realtimeV3WebSocketFrame(result)
    expect(frame.length).toBeGreaterThan(1_048_576)
    expect(frame.length).toBeLessThanOrEqual(MAX_PACKET_BYTES + 4)
    const decoded = decodeGetUpdatesFrame(frame)
    expect(decoded.seq).toBe(1n)
    expect(decoded.updates).toHaveLength(1)
    const decodedUpdate = decoded.updates[0]
    expect(decodedUpdate?.update.oneofKind).toBe("newMessage")
    if (decodedUpdate?.update.oneofKind !== "newMessage") {
      throw new Error("Expected decoded newMessage update")
    }
    expect(decodedUpdate.update.newMessage.message).toMatchObject({
      id: 1n,
      fromId: BigInt(user.id),
      chatId: BigInt(chat.id),
      message: expectedMessage,
      out: true,
    })
  })

  test("rejects invalid page limits", async () => {
    const { users } = await testUtils.createSpaceWithMembers("Invalid Page Limit", ["invalid-page-limit@example.com"])
    const user = users[0]
    if (!user) throw new Error("User creation failed")

    await expect(getUpdates({
      bucket: { type: { oneofKind: "user", user: {} } },
      startSeq: 0n,
      seqEnd: 0n,
      totalLimit: 0,
      limit: 1.5,
    }, { currentUserId: user.id } as any)).rejects.toMatchObject({ code: RealtimeRpcError.Code.BAD_REQUEST })
  })

  test("rejects sequences outside the PostgreSQL integer domain", async () => {
    const { users } = await testUtils.createSpaceWithMembers("Sequence Domain", ["sequence-domain@example.com"])
    const user = users[0]
    if (!user) throw new Error("User creation failed")

    await expect(getUpdates({
      bucket: { type: { oneofKind: "user", user: {} } },
      startSeq: 2_147_483_648n,
      seqEnd: 0n,
      totalLimit: 0,
      limit: 100,
    }, { currentUserId: user.id } as any)).rejects.toMatchObject({ code: RealtimeRpcError.Code.BAD_REQUEST })

    await expect(getUpdates({
      bucket: { type: { oneofKind: "user", user: {} } },
      startSeq: 0n,
      seqEnd: 2_147_483_648n,
      totalLimit: 0,
      limit: 100,
    }, { currentUserId: user.id } as any)).rejects.toMatchObject({ code: RealtimeRpcError.Code.BAD_REQUEST })
  })

  test("requests authoritative repair for a non-contiguous durable page without delivering a partial slice", async () => {
    const { users } = await testUtils.createSpaceWithMembers("Sparse Page", ["sparse-page@example.com"])
    const user = users[0]
    if (!user) throw new Error("User creation failed")

    await insertServerUpdate({
      bucket: UpdateBucket.User,
      entityId: user.id,
      seq: 1,
      payload: {
        oneofKind: "userChatParticipantDelete",
        userChatParticipantDelete: { chatId: 1n },
      },
    })
    await insertServerUpdate({
      bucket: UpdateBucket.User,
      entityId: user.id,
      seq: 3,
      payload: {
        oneofKind: "userChatParticipantDelete",
        userChatParticipantDelete: { chatId: 3n },
      },
    })

    const result = await getUpdates({
      bucket: { type: { oneofKind: "user", user: {} } },
      startSeq: 0n,
      seqEnd: 0n,
      totalLimit: 0,
      limit: 100,
    }, { currentUserId: user.id } as any)

    expect(result.resultType).toBe(GetUpdatesResult_ResultType.TOO_LONG)
    expect(result.seq).toBe(3n)
    expect(result.final).toBe(false)
    expect(result.updates).toEqual([])
    expect(result.skippedSequences).toEqual([])
  })

  test("does not return a cursor behind startSeq", async () => {
    const { users } = await testUtils.createSpaceWithMembers("Cursor Clamp", ["cursor-clamp@example.com"])
    const user = users[0]
    if (!user) throw new Error("User creation failed")

    await insertServerUpdate({
      bucket: UpdateBucket.User,
      entityId: user.id,
      seq: 1,
      payload: {
        oneofKind: "userChatParticipantDelete",
        userChatParticipantDelete: {
          chatId: 1n,
        },
      },
    })

    const result = await getUpdates({
      bucket: { type: { oneofKind: "user", user: {} } },
      startSeq: 5n,
      seqEnd: 0n,
      totalLimit: 1000,
      limit: 10,
    }, { currentUserId: user.id } as any)

    expect(Number(result.seq)).toBe(5)
    expect(result.final).toBe(true)
    expect(result.resultType).toBe(GetUpdatesResult_ResultType.EMPTY)
    expect(result.updates).toHaveLength(0)
    expect(result.date).toBe(0n)
  })

  test("requests repair for fully pruned user, space, and chat journals using their durable tails", async () => {
    const { users: fixtureUsers, space } = await testUtils.createSpaceWithMembers("Pruned Buckets", ["pruned-buckets@example.com"])
    const user = fixtureUsers[0]
    const chat = await testUtils.createChat(space.id, "Pruned Chat", "thread", true)
    if (!user || !chat) throw new Error("Failed to create pruned bucket fixtures")
    const date = new Date("2026-08-31T00:00:00Z")
    await db.update(usersTable).set({ updateSeq: 3, lastUpdateDate: date }).where(eq(usersTable.id, user.id))
    await db.update(spaces).set({ updateSeq: 3, lastUpdateDate: date }).where(eq(spaces.id, space.id))
    await db.update(chats).set({ updateSeq: 3, lastUpdateDate: date }).where(eq(chats.id, chat.id))
    const buckets: GetUpdatesInput["bucket"][] = [
      { type: { oneofKind: "user", user: {} } },
      { type: { oneofKind: "space", space: { spaceId: BigInt(space.id) } } },
      { type: { oneofKind: "chat", chat: { peerId: { type: { oneofKind: "chat", chat: { chatId: BigInt(chat.id) } } } } } },
    ]
    for (const bucket of buckets) {
      const result = await getUpdates({ bucket, startSeq: 0n, seqEnd: 0n, totalLimit: 0, limit: 100 }, { currentUserId: user.id } as any)
      expect(result.resultType).toBe(GetUpdatesResult_ResultType.TOO_LONG)
      expect(result.seq).toBe(3n)
      expect(result.date).toBe(encodeDateStrict(date))
      expect(result.final).toBe(false)
      expect(result.updates).toEqual([])
    }
  })

  test.each([1, 2])("requests repair for a pruned journal around retained sequence %s", async (retainedSeq) => {
    const user = await testUtils.createUser(`pruned-retained-${retainedSeq}@example.com`)
    await db.update(usersTable).set({ updateSeq: 3 }).where(eq(usersTable.id, user.id))
    await insertServerUpdate({
      bucket: UpdateBucket.User,
      entityId: user.id,
      seq: retainedSeq,
      payload: { oneofKind: "userChatParticipantDelete", userChatParticipantDelete: { chatId: 1n } },
    })
    const result = await getUpdates({
      bucket: { type: { oneofKind: "user", user: {} } }, startSeq: 0n, seqEnd: 0n, totalLimit: 0, limit: 100,
    }, { currentUserId: user.id } as any)
    expect(result.resultType).toBe(GetUpdatesResult_ResultType.TOO_LONG)
    expect(result.seq).toBe(3n)
    expect(result.updates).toEqual([])
  })

  test("does not extend a fixed replay target to the current entity tail", async () => {
    const user = await testUtils.createUser("bounded-entity-tail@example.com")
    await db.update(usersTable).set({ updateSeq: 3 }).where(eq(usersTable.id, user.id))
    await insertServerUpdate({
      bucket: UpdateBucket.User,
      entityId: user.id,
      seq: 1,
      payload: { oneofKind: "userChatParticipantDelete", userChatParticipantDelete: { chatId: 1n } },
    })
    const result = await getUpdates({
      bucket: { type: { oneofKind: "user", user: {} } }, startSeq: 0n, seqEnd: 1n, totalLimit: 0, limit: 100,
    }, { currentUserId: user.id } as any)
    expect(result.resultType).toBe(GetUpdatesResult_ResultType.SLICE)
    expect(result.seq).toBe(1n)
    expect(result.final).toBe(true)
  })

  test("accounts for a filtered record before advancing past later updates", async () => {
    const { users } = await testUtils.createSpaceWithMembers("Filtered Cursor", ["filtered-cursor@example.com"])
    const user = users[0]
    if (!user) throw new Error("User creation failed")

    await insertServerUpdate({
      bucket: UpdateBucket.User,
      entityId: user.id,
      seq: 1,
      payload: {
        oneofKind: "newMessage",
        newMessage: {
          chatId: 1n,
          msgId: 1n,
        },
      },
    })
    await insertServerUpdate({
      bucket: UpdateBucket.User,
      entityId: user.id,
      seq: 2,
      payload: {
        oneofKind: "userChatParticipantDelete",
        userChatParticipantDelete: {
          chatId: 2n,
        },
      },
    })

    const result = await getUpdates({
      bucket: { type: { oneofKind: "user", user: {} } },
      startSeq: 0n,
      seqEnd: 0n,
      totalLimit: 1000,
      limit: 0,
    }, { currentUserId: user.id } as any)

    expect(result.seq).toBe(2n)
    expect(result.final).toBe(true)
    expect(result.resultType).toBe(GetUpdatesResult_ResultType.SLICE)
    expect(result.updates.map((update) => update.update.oneofKind)).toEqual(["participantDelete"])
    expect(result.skippedSequences).toEqual([
      {
        seq: 1n,
        reason: SyncSkippedSequence_Reason.IRRELEVANT_TO_BUCKET,
      },
    ])
  })

  test("accounts for an unknown durable user update and continues", async () => {
    const { users } = await testUtils.createSpaceWithMembers("Unknown Catalog Entry", ["unknown-catalog@example.com"])
    const user = users[0]
    if (!user) throw new Error("User creation failed")

    await insertServerUpdate({
      bucket: UpdateBucket.User,
      entityId: user.id,
      seq: 1,
      payload: { oneofKind: undefined },
    })
    await insertServerUpdate({
      bucket: UpdateBucket.User,
      entityId: user.id,
      seq: 2,
      payload: {
        oneofKind: "userChatParticipantDelete",
        userChatParticipantDelete: { chatId: 2n },
      },
    })

    const result = await getUpdates({
      bucket: { type: { oneofKind: "user", user: {} } },
      startSeq: 0n,
      seqEnd: 0n,
      totalLimit: 0,
      limit: 100,
    }, { currentUserId: user.id } as any)

    expect(result.seq).toBe(2n)
    expect(result.updates.map((update) => update.update.oneofKind)).toEqual(["participantDelete"])
    expect(result.skippedSequences).toEqual([{
      seq: 1n,
      reason: SyncSkippedSequence_Reason.IRRELEVANT_TO_BUCKET,
    }])
  })

  test("serves group grants with chat and group sidecars", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Group Grant Sidecars", [
      "group-sidecar-owner@example.com",
      "group-sidecar-old@example.com",
      "group-sidecar-new@example.com",
    ])
    const [owner, oldMember, newMember] = users
    if (!space || !owner || !oldMember || !newMember) {
      throw new Error("Failed to create group sidecar fixtures")
    }

    await db
      .update(members)
      .set({ role: "owner" })
      .where(and(eq(members.spaceId, space.id), eq(members.userId, owner.id)))

    const createdGroup = await createUserGroup(
      {
        spaceId: space.id,
        name: "Reviewers",
        userIds: [oldMember.id],
      },
      { currentUserId: owner.id } as any,
    )
    const groupId = Number(createdGroup.group.id)

    const chat = await testUtils.createChat(space.id, "Private Review Thread", "thread", false, owner.id)
    if (!chat) {
      throw new Error("Failed to create private group thread")
    }
    await testUtils.addParticipant(chat.id, owner.id)
    await addChatParticipant({ chatId: chat.id, groupId }, { currentUserId: owner.id } as any)

    await updateUserGroup(
      {
        groupId,
        name: "Reviewers",
        userIds: [oldMember.id, newMember.id],
      },
      { currentUserId: owner.id } as any,
    )

    const result = await getUpdates(
      {
        bucket: { type: { oneofKind: "user", user: {} } },
        startSeq: 0n,
        seqEnd: 0n,
        totalLimit: 1000,
        limit: 10,
      },
      { currentUserId: newMember.id } as any,
    )

    expect(result.updates.map((update) => update.update.oneofKind)).toEqual([
      "userAddedToChat",
      "chatPermissions",
    ])
    const accessUpdate = result.updates[0]?.update
    expect(accessUpdate?.oneofKind).toBe("userAddedToChat")
    if (accessUpdate?.oneofKind !== "userAddedToChat") throw new Error("Expected userAddedToChat")
    expect(Number(accessUpdate.userAddedToChat.chatId)).toBe(chat.id)
    expect(Number(accessUpdate.userAddedToChat.group?.groupId)).toBe(groupId)
    const permissionUpdate = result.updates[1]?.update
    expect(permissionUpdate?.oneofKind).toBe("chatPermissions")
    if (permissionUpdate?.oneofKind !== "chatPermissions") {
      throw new Error("Expected a chatPermissions update")
    }
    expect(Number(permissionUpdate.chatPermissions.chatId)).toBe(chat.id)
    expect(permissionUpdate.chatPermissions.permissions?.canUpdateInfo).toBe(false)
    expect(result.sidecars?.chats.map((sidecar) => Number(sidecar.id))).toContain(chat.id)
    expect(result.sidecars?.spaces.map((sidecar) => Number(sidecar.id))).toContain(space.id)

    const groupSidecar = result.sidecars?.userGroups.find((group) => Number(group.id) === groupId)
    expect(groupSidecar).toBeDefined()
    expect(groupSidecar?.currentUserIsMember).toBe(true)
    expect(groupSidecar?.userIds.map(Number).sort((a, b) => a - b)).toEqual(
      [oldMember.id, newMember.id].sort((a, b) => a - b),
    )

    const sidecarUserIds = new Set(result.sidecars?.users.map((user) => Number(user.id)) ?? [])
    expect(sidecarUserIds.has(oldMember.id)).toBe(true)
    expect(sidecarUserIds.has(newMember.id)).toBe(true)
  })

  test("serves participant deletion without enriching a now-inaccessible chat", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Participant Delete Sidecars", [
      "participant-delete@example.com",
    ])
    const user = users[0]
    if (!space || !user) throw new Error("Failed to create participant delete fixtures")

    const chat = await testUtils.createChat(space.id, "Removed Private Thread", "thread", false)
    if (!chat) throw new Error("Failed to create participant delete chat")

    await insertServerUpdate({
      bucket: UpdateBucket.User,
      entityId: user.id,
      seq: 1,
      payload: {
        oneofKind: "userChatParticipantDelete",
        userChatParticipantDelete: { chatId: BigInt(chat.id) },
      },
    })

    const result = await getUpdates(
      {
        bucket: { type: { oneofKind: "user", user: {} } },
        startSeq: 0n,
        seqEnd: 0n,
        totalLimit: 1000,
        limit: 10,
      },
      { currentUserId: user.id } as any,
    )

    expect(result.updates.map((update) => update.update.oneofKind)).toEqual(["participantDelete"])
    expect(result.sidecars).toBeUndefined()
  })

  test("serves participant additions with the chat and added-user dependency sidecars", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Participant Add Sidecars", [
      "participant-add-viewer@example.com",
      "participant-add-new@example.com",
    ])
    const viewer = users[0]
    const addedUser = users[1]
    if (!space || !viewer || !addedUser) throw new Error("Failed to create participant add fixtures")

    const chat = await testUtils.createChat(space.id, "Private Participant Add", "thread", false)
    if (!chat) throw new Error("Failed to create participant add chat")
    await testUtils.addParticipant(chat.id, viewer.id)
    await testUtils.addParticipant(chat.id, addedUser.id)

    await insertServerUpdate({
      bucket: UpdateBucket.Chat,
      entityId: chat.id,
      seq: 1,
      payload: {
        oneofKind: "participantAdd",
        participantAdd: {
          chatId: BigInt(chat.id),
          participant: {
            userId: BigInt(addedUser.id),
            date: 1n,
          },
        },
      },
    })

    const result = await getUpdates(
      {
        bucket: {
          type: {
            oneofKind: "chat",
            chat: {
              peerId: {
                type: {
                  oneofKind: "chat",
                  chat: { chatId: BigInt(chat.id) },
                },
              },
            },
          },
        },
        startSeq: 0n,
        seqEnd: 0n,
        totalLimit: 1000,
        limit: 10,
      },
      { currentUserId: viewer.id } as any,
    )

    expect(result.updates.map((update) => update.update.oneofKind)).toEqual(["participantAdd"])
    expect(result.sidecars?.chats.map((sidecar) => Number(sidecar.id))).toContain(chat.id)
    expect(result.sidecars?.spaces.map((sidecar) => Number(sidecar.id))).toContain(space.id)
    expect(result.sidecars?.users.map((sidecar) => Number(sidecar.id))).toContain(addedUser.id)
  })

  test("does not disclose payload-selected chat or user sidecars for malformed participant additions", async () => {
    const { space: sourceSpace, users: sourceUsers } = await testUtils.createSpaceWithMembers(
      "Malformed Participant Source",
      ["malformed-participant-viewer@example.com"],
    )
    const { space: foreignSpace, users: foreignUsers } = await testUtils.createSpaceWithMembers(
      "Malformed Participant Foreign",
      ["malformed-participant-foreign@example.com"],
    )
    const viewer = sourceUsers[0]
    const foreignUser = foreignUsers[0]
    if (!sourceSpace || !foreignSpace || !viewer || !foreignUser) {
      throw new Error("Failed to create malformed participant privacy fixtures")
    }

    const sourceChat = await testUtils.createChat(sourceSpace.id, "Source Private Thread", "thread", false)
    const foreignChat = await testUtils.createChat(foreignSpace.id, "Foreign Private Thread", "thread", false)
    if (!sourceChat || !foreignChat) throw new Error("Failed to create malformed participant privacy chats")
    await testUtils.addParticipant(sourceChat.id, viewer.id)
    await testUtils.addParticipant(foreignChat.id, foreignUser.id)
    // Even a retained, corrupt direct grant does not confer space membership.
    await testUtils.addParticipant(sourceChat.id, foreignUser.id)
    const [foreignGroup] = await db.insert(userGroups).values({
      spaceId: foreignSpace.id, name: "Private Foreign Group", createdBy: foreignUser.id,
    }).returning()
    if (!foreignGroup) throw new Error("Failed to create foreign group")
    await db.insert(chatParticipantGroups).values({ chatId: sourceChat.id, groupId: foreignGroup.id })

    await insertServerUpdate({
      bucket: UpdateBucket.Chat,
      entityId: sourceChat.id,
      seq: 1,
      payload: {
        oneofKind: "participantAdd",
        participantAdd: {
          chatId: BigInt(foreignChat.id),
          participant: { userId: BigInt(foreignUser.id), date: 1n },
        },
      },
    })

    await insertServerUpdate({
      bucket: UpdateBucket.Chat,
      entityId: sourceChat.id,
      seq: 2,
      payload: { oneofKind: "participantAdd", participantAdd: {
        chatId: BigInt(sourceChat.id), participant: { userId: BigInt(foreignUser.id), date: 1n },
      } },
    })
    await insertServerUpdate({
      bucket: UpdateBucket.Chat,
      entityId: sourceChat.id,
      seq: 3,
      payload: { oneofKind: "participantGroupAdd", participantGroupAdd: {
        chatId: BigInt(sourceChat.id), groupParticipant: { groupId: BigInt(foreignGroup.id), date: 1n },
      } },
    })

    const result = await getUpdates(
      {
        bucket: {
          type: {
            oneofKind: "chat",
            chat: {
              peerId: {
                type: { oneofKind: "chat", chat: { chatId: BigInt(sourceChat.id) } },
              },
            },
          },
        },
        startSeq: 0n,
        seqEnd: 0n,
        totalLimit: 1000,
        limit: 10,
      },
      { currentUserId: viewer.id } as any,
    )

    expect(result.updates.map((update) => update.update.oneofKind)).toEqual(["chatSkipPts", "chatSkipPts", "chatSkipPts"])
    expect(result.sidecars?.chats.map((sidecar) => Number(sidecar.id))).toContain(sourceChat.id)
    expect(result.sidecars?.chats.map((sidecar) => Number(sidecar.id))).not.toContain(foreignChat.id)
    expect(result.sidecars?.spaces.map((sidecar) => Number(sidecar.id))).not.toContain(foreignSpace.id)
    expect(result.sidecars?.users.map((sidecar) => Number(sidecar.id))).not.toContain(foreignUser.id)
    expect(result.sidecars?.userGroups).toEqual([])
  })

  test("serves join-space updates with the current-user dependency", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Join Space Sidecars", [
      "join-space-sidecar@example.com",
    ])
    const user = users[0]
    if (!space || !user) throw new Error("Failed to create join-space fixtures")

    const [member] = await db
      .select()
      .from(members)
      .where(and(eq(members.spaceId, space.id), eq(members.userId, user.id)))
      .limit(1)
    if (!member) throw new Error("Failed to load join-space member fixture")

    await insertServerUpdate({
      bucket: UpdateBucket.User,
      entityId: user.id,
      seq: 1,
      payload: {
        oneofKind: "userJoinSpace",
        userJoinSpace: {
          space: {
            id: BigInt(space.id),
            name: space.name,
            date: 1n,
            creator: false,
          },
          member: {
            id: BigInt(member.id),
            spaceId: BigInt(space.id),
            userId: BigInt(user.id),
            role: Member_Role.MEMBER,
            date: 1n,
            canAccessPublicChats: true,
          },
        },
      },
    })

    const result = await getUpdates(
      {
        bucket: { type: { oneofKind: "user", user: {} } },
        startSeq: 0n,
        seqEnd: 0n,
        totalLimit: 1000,
        limit: 10,
      },
      { currentUserId: user.id } as any,
    )

    expect(result.updates.map((update) => update.update.oneofKind)).toEqual(["joinSpace"])
    expect(result.sidecars?.users.map((sidecar) => Number(sidecar.id))).toContain(user.id)
  })

  test("accounts obsolete user access-adds without enriching revoked private chat or group metadata", async () => {
    const { space, users: fixtureUsers } = await testUtils.createSpaceWithMembers("Revoked Replay", [
      "revoked-replay-owner@example.com", "revoked-replay-viewer@example.com", "revoked-replay-secret@example.com",
    ])
    const [owner, viewer, secretUser] = fixtureUsers
    if (!owner || !viewer || !secretUser) throw new Error("Missing revoked replay users")
    const chat = await testUtils.createChat(space.id, "Previously Visible Thread", "thread", false)
    if (!chat) throw new Error("Missing revoked replay chat")
    await testUtils.addParticipant(chat.id, viewer.id)
    const [group] = await db.insert(userGroups).values({ spaceId: space.id, name: "Old Group", createdBy: owner.id }).returning()
    if (!group) throw new Error("Missing revoked replay group")
    await db.insert(chatParticipantGroups).values({ chatId: chat.id, groupId: group.id })
    await db.insert(userGroupMembers).values({ groupId: group.id, userId: viewer.id })
    await db.insert(dialogs).values({ chatId: chat.id, userId: viewer.id, spaceId: space.id })
    await insertServerUpdate({
      bucket: UpdateBucket.User, entityId: viewer.id, seq: 1,
      payload: { oneofKind: "userAddedToChat", userAddedToChat: {
        chatId: BigInt(chat.id), group: { groupId: BigInt(group.id), date: 1n },
      } },
    })
    await insertServerUpdate({
      bucket: UpdateBucket.User, entityId: viewer.id, seq: 2,
      payload: { oneofKind: "userSpaceMemberDelete", userSpaceMemberDelete: { spaceId: BigInt(space.id) } },
    })
    // Retained dialog/participant/group rows deliberately survive membership exit.
    await db.delete(members).where(and(eq(members.spaceId, space.id), eq(members.userId, viewer.id)))
    await db.update(chats).set({ title: "Private New Title" }).where(eq(chats.id, chat.id))
    await db.update(userGroups).set({ name: "Private New Group Name" }).where(eq(userGroups.id, group.id))
    await db.insert(userGroupMembers).values({ groupId: group.id, userId: secretUser.id })

    const result = await getUpdates({
      bucket: { type: { oneofKind: "user", user: {} } }, startSeq: 0n, seqEnd: 0n, totalLimit: 0, limit: 100,
    }, { currentUserId: viewer.id } as any)
    expect(result.seq).toBe(2n)
    expect(result.final).toBe(true)
    expect(result.updates.map((update) => update.update.oneofKind)).toEqual(["spaceMemberDelete"])
    expect(result.skippedSequences).toEqual([{ seq: 1n, reason: SyncSkippedSequence_Reason.IRRELEVANT_TO_BUCKET }])
    expect(result.sidecars).toBeUndefined()
  })

  test("serves a complete chatOpen envelope while chat access remains current", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Current Chat Open", ["current-chat-open@example.com"])
    const viewer = users[0]
    if (!viewer) throw new Error("Missing current chatOpen viewer")
    const chat = await testUtils.createChat(space.id, "Current Private Thread", "thread", false)
    if (!chat) throw new Error("Missing current chatOpen chat")
    await testUtils.addParticipant(chat.id, viewer.id)
    const [dialog] = await db.insert(dialogs).values({ chatId: chat.id, userId: viewer.id, spaceId: space.id }).returning()
    if (!dialog) throw new Error("Missing current chatOpen dialog")

    await insertServerUpdate({
      bucket: UpdateBucket.User, entityId: viewer.id, seq: 1,
      payload: { oneofKind: "userChatOpen", userChatOpen: {
        chat: Encoders.chat(chat, { encodingForUserId: viewer.id }),
        dialog: Encoders.dialog(dialog, { unreadCount: 0 }),
      } },
    })

    const result = await getUpdates({
      bucket: { type: { oneofKind: "user", user: {} } }, startSeq: 0n, seqEnd: 0n, totalLimit: 0, limit: 100,
    }, { currentUserId: viewer.id } as any)

    expect(result.updates.map((update) => update.update.oneofKind)).toEqual(["chatOpen"])
    expect(result.skippedSequences).toEqual([])
    expect(result.sidecars?.chats.map((row) => Number(row.id))).toContain(chat.id)
  })

  test("accounts a revoked chatOpen without disclosing its embedded snapshot and still delivers removal", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Revoked Chat Open", ["revoked-chat-open@example.com"])
    const viewer = users[0]
    if (!viewer) throw new Error("Missing revoked chatOpen viewer")
    const chat = await testUtils.createChat(space.id, "Historical Private Thread", "thread", false)
    if (!chat) throw new Error("Missing revoked chatOpen chat")
    await testUtils.addParticipant(chat.id, viewer.id)
    const [dialog] = await db.insert(dialogs).values({ chatId: chat.id, userId: viewer.id, spaceId: space.id }).returning()
    if (!dialog) throw new Error("Missing revoked chatOpen dialog")

    await insertServerUpdate({
      bucket: UpdateBucket.User, entityId: viewer.id, seq: 1,
      payload: { oneofKind: "userChatOpen", userChatOpen: {
        chat: Encoders.chat(chat, { encodingForUserId: viewer.id }),
        dialog: Encoders.dialog(dialog, { unreadCount: 0 }),
      } },
    })
    await insertServerUpdate({
      bucket: UpdateBucket.User, entityId: viewer.id, seq: 2,
      payload: { oneofKind: "userRemovedFromChat", userRemovedFromChat: { chatId: BigInt(chat.id) } },
    })
    await db.delete(chatParticipants).where(and(
      eq(chatParticipants.chatId, chat.id),
      eq(chatParticipants.userId, viewer.id),
    ))

    const result = await getUpdates({
      bucket: { type: { oneofKind: "user", user: {} } }, startSeq: 0n, seqEnd: 0n, totalLimit: 0, limit: 100,
    }, { currentUserId: viewer.id } as any)

    expect(result.seq).toBe(2n)
    expect(result.final).toBe(true)
    expect(result.updates.map((update) => update.update.oneofKind)).toEqual(["userRemovedFromChat"])
    expect(result.skippedSequences).toEqual([{ seq: 1n, reason: SyncSkippedSequence_Reason.IRRELEVANT_TO_BUCKET }])
    expect(result.sidecars).toBeUndefined()
  })

  test("accounts a malformed chatOpen envelope while continuing the user replay", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Malformed Chat Open", ["malformed-chat-open@example.com"])
    const viewer = users[0]
    if (!viewer) throw new Error("Missing malformed chatOpen viewer")
    const chat = await testUtils.createChat(space.id, "Accessible Thread", "thread", false)
    if (!chat) throw new Error("Missing malformed chatOpen chat")
    await testUtils.addParticipant(chat.id, viewer.id)
    const [dialog] = await db.insert(dialogs).values({ chatId: chat.id, userId: viewer.id, spaceId: space.id }).returning()
    if (!dialog) throw new Error("Missing malformed chatOpen dialog")
    const malformedDialog = { ...Encoders.dialog(dialog, { unreadCount: 0 }), chatId: BigInt(chat.id + 1) }

    await insertServerUpdate({
      bucket: UpdateBucket.User, entityId: viewer.id, seq: 1,
      payload: { oneofKind: "userChatOpen", userChatOpen: {
        chat: Encoders.chat(chat, { encodingForUserId: viewer.id }),
        dialog: malformedDialog,
      } },
    })
    await insertServerUpdate({
      bucket: UpdateBucket.User, entityId: viewer.id, seq: 2,
      payload: { oneofKind: "userChatParticipantDelete", userChatParticipantDelete: { chatId: BigInt(chat.id) } },
    })

    const result = await getUpdates({
      bucket: { type: { oneofKind: "user", user: {} } }, startSeq: 0n, seqEnd: 0n, totalLimit: 0, limit: 100,
    }, { currentUserId: viewer.id } as any)

    expect(result.seq).toBe(2n)
    expect(result.final).toBe(true)
    expect(result.updates.map((update) => update.update.oneofKind)).toEqual(["participantDelete"])
    expect(result.skippedSequences).toEqual([{ seq: 1n, reason: SyncSkippedSequence_Reason.IRRELEVANT_TO_BUCKET }])
  })

  test("preserves current chat discovery while stripping an obsolete optional group grant", async () => {
    const { space, users: fixtureUsers } = await testUtils.createSpaceWithMembers("Retired Group Replay", ["retired-group-viewer@example.com"])
    const viewer = fixtureUsers[0]
    if (!viewer) throw new Error("Missing retired group viewer")
    const chat = await testUtils.createChat(space.id, "Still Accessible Thread", "thread", false)
    if (!chat) throw new Error("Missing retired group chat")
    await testUtils.addParticipant(chat.id, viewer.id)
    const group = { groupId: 9_999_999n, date: 1n }
    await insertServerUpdate({
      bucket: UpdateBucket.User, entityId: viewer.id, seq: 1,
      payload: { oneofKind: "userAddedToChat", userAddedToChat: { chatId: BigInt(chat.id), group } },
    })
    await insertServerUpdate({
      bucket: UpdateBucket.User, entityId: viewer.id, seq: 2,
      payload: { oneofKind: "userChatParticipantGroupAdd", userChatParticipantGroupAdd: { chatId: BigInt(chat.id), groupParticipant: group } },
    })
    const result = await getUpdates({
      bucket: { type: { oneofKind: "user", user: {} } }, startSeq: 0n, seqEnd: 0n, totalLimit: 0, limit: 100,
    }, { currentUserId: viewer.id } as any)
    expect(result.seq).toBe(2n)
    expect(result.updates).toHaveLength(1)
    const delivered = result.updates[0]?.update
    if (delivered?.oneofKind !== "userAddedToChat") throw new Error("Expected current discovery event")
    expect(delivered.userAddedToChat.chatId).toBe(BigInt(chat.id))
    expect(delivered.userAddedToChat.group).toBeUndefined()
    expect(result.sidecars?.chats.map((row) => Number(row.id))).toContain(chat.id)
    expect(result.sidecars?.userGroups).toEqual([])
    expect(result.skippedSequences).toEqual([{ seq: 2n, reason: SyncSkippedSequence_Reason.IRRELEVANT_TO_BUCKET }])
  })

  test("serves member updates with their space and user dependencies", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Member Update Sidecars", [
      "member-update@example.com",
    ])
    const user = users[0]
    if (!space || !user) throw new Error("Failed to create member update fixtures")

    const [member] = await db
      .select()
      .from(members)
      .where(and(eq(members.spaceId, space.id), eq(members.userId, user.id)))
      .limit(1)
    if (!member) throw new Error("Failed to load member update fixture")

    await insertServerUpdate({
      bucket: UpdateBucket.Space,
      entityId: space.id,
      seq: 1,
      payload: {
        oneofKind: "spaceMemberUpdate",
        spaceMemberUpdate: {
          member: {
            id: BigInt(member.id),
            spaceId: BigInt(space.id),
            userId: BigInt(user.id),
            role: Member_Role.MEMBER,
            date: 1n,
            canAccessPublicChats: true,
          },
        },
      },
    })

    const result = await getUpdates(
      {
        bucket: { type: { oneofKind: "space", space: { spaceId: BigInt(space.id) } } },
        startSeq: 0n,
        seqEnd: 0n,
        totalLimit: 1000,
        limit: 10,
      },
      { currentUserId: user.id } as any,
    )

    expect(result.updates.map((update) => update.update.oneofKind)).toEqual(["spaceMemberUpdate"])
    expect(result.sidecars?.spaces.map((sidecar) => Number(sidecar.id))).toContain(space.id)
    expect(result.sidecars?.users.map((sidecar) => Number(sidecar.id))).toContain(user.id)
  })

  test("sanitizes public space member add updates for regular members", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Public Update Space", [
      "regular-public-updates@example.com",
      "new-public-updates@example.com",
    ])
    const [regularUser, newUser] = users
    await db.update(spaces).set({ isPublic: true }).where(eq(spaces.id, space.id))
    const [newMember] = await db
      .select()
      .from(members)
      .where(and(eq(members.spaceId, space.id), eq(members.userId, newUser.id)))
      .limit(1)
    if (!newMember) throw new Error("missing member")

    await insertServerUpdate({
      bucket: UpdateBucket.Space,
      entityId: space.id,
      seq: 1,
      payload: {
        oneofKind: "spaceMemberAdd",
        spaceMemberAdd: {
          member: {
            id: BigInt(newMember.id),
            spaceId: BigInt(space.id),
            userId: BigInt(newUser.id),
            role: Member_Role.MEMBER,
            date: 1n,
            canAccessPublicChats: true,
          },
          user: {
            id: BigInt(newUser.id),
            firstName: "New",
            email: "new-public-updates@example.com",
            phoneNumber: "+15555550100",
            timeZone: "UTC",
          },
        },
      },
    })

    const result = await getUpdates(
      {
        bucket: { type: { oneofKind: "space", space: { spaceId: BigInt(space.id) } } },
        startSeq: 0n,
        seqEnd: 0n,
        totalLimit: 1000,
        limit: 10,
      },
      { currentUserId: regularUser.id } as any,
    )

    const update = result.updates[0]?.update
    expect(update?.oneofKind).toBe("spaceMemberAdd")
    if (update?.oneofKind !== "spaceMemberAdd") throw new Error("missing member add update")
    expect(update.spaceMemberAdd.user?.id).toBe(BigInt(newUser.id))
    expect(update.spaceMemberAdd.user?.email).toBeUndefined()
    expect(update.spaceMemberAdd.user?.phoneNumber).toBeUndefined()
    expect(update.spaceMemberAdd.user?.timeZone).toBeUndefined()
    expect(update.spaceMemberAdd.user?.min).toBe(true)
    expect(result.sidecars?.spaces.map((sidecar) => Number(sidecar.id))).toContain(space.id)
    expect(result.sidecars?.users.map((sidecar) => Number(sidecar.id))).toContain(newUser.id)
  })

  test("does not let the client totalLimit force TOO_LONG", async () => {
    const { users } = await testUtils.createSpaceWithMembers("Server Replay Limit", ["server-limit@example.com"])
    const user = users[0]
    if (!user) throw new Error("User creation failed")

    for (let seq = 1; seq <= 2; seq += 1) {
      await insertServerUpdate({
        bucket: UpdateBucket.User,
        entityId: user.id,
        seq,
        payload: {
          oneofKind: "userChatParticipantDelete",
          userChatParticipantDelete: { chatId: BigInt(seq) },
        },
      })
    }

    const result = await getUpdates({
      bucket: { type: { oneofKind: "user", user: {} } },
      startSeq: 0n,
      seqEnd: 0n,
      totalLimit: 1,
      limit: 0,
    }, { currentUserId: user.id } as any)

    expect(result.resultType).toBe(GetUpdatesResult_ResultType.SLICE)
    expect(result.updates).toHaveLength(2)
    expect(result.final).toBe(true)
  })

  test("advances over missing newMessage targets with chatSkipPts", async () => {
    const { users, space } = await testUtils.createSpaceWithMembers("Missing Message Update", ["missing@example.com"])
    const user = users[0]
    if (!user || !space) throw new Error("Fixture creation failed")

    const chat = await testUtils.createChat(space.id, "Missing Message Chat", "thread", true)
    if (!chat) throw new Error("Chat creation failed")

    await insertServerUpdate({
      bucket: UpdateBucket.Chat,
      entityId: chat.id,
      seq: 1,
      payload: {
        oneofKind: "newMessage",
        newMessage: {
          chatId: BigInt(chat.id),
          msgId: 1n,
        },
      },
    })
    await db.insert(messages).values({
      chatId: chat.id,
      messageId: 2,
      fromId: user.id,
      text: "this should not be delivered before seq 1 inflates",
    })
    await insertServerUpdate({
      bucket: UpdateBucket.Chat,
      entityId: chat.id,
      seq: 2,
      payload: {
        oneofKind: "newMessage",
        newMessage: {
          chatId: BigInt(chat.id),
          msgId: 2n,
        },
      },
    })

    const inputPeer: InputPeer = {
      type: {
        oneofKind: "chat",
        chat: { chatId: BigInt(chat.id) },
      },
    }

    const result = await getUpdates(
      {
        bucket: {
          type: {
            oneofKind: "chat",
            chat: { peerId: inputPeer },
          },
        },
        startSeq: 0n,
        seqEnd: 0n,
        totalLimit: 1000,
        limit: 0,
      },
      { currentUserId: user.id } as any,
    )

    expect(result.seq).toBe(2n)
    expect(result.final).toBe(true)
    expect(result.resultType).toBe(GetUpdatesResult_ResultType.SLICE)
    expect(result.updates.map((update) => update.update.oneofKind)).toEqual(["chatSkipPts", "newMessage"])
  })

  test("drains previously persisted reaction records as chatSkipPts", async () => {
    const { users, space } = await testUtils.createSpaceWithMembers("Legacy Durable Reaction", [
      "legacy-durable-reaction@example.com",
    ])
    const user = users[0]
    if (!user || !space) throw new Error("Fixture creation failed")

    const chat = await testUtils.createChat(space.id, "Legacy Durable Reaction Chat", "thread", true)
    if (!chat) throw new Error("Chat creation failed")

    await insertServerUpdate({
      bucket: UpdateBucket.Chat,
      entityId: chat.id,
      seq: 1,
      payload: {
        oneofKind: "reaction",
        reaction: {
          reaction: {
            emoji: "👍",
            chatId: BigInt(chat.id),
            messageId: 1n,
            userId: BigInt(user.id),
            date: encodeDateStrict(new Date()),
          },
        },
      },
    })
    await insertServerUpdate({
      bucket: UpdateBucket.Chat,
      entityId: chat.id,
      seq: 2,
      payload: {
        oneofKind: "reactionDeleted",
        reactionDeleted: {
          emoji: "👍",
          chatId: BigInt(chat.id),
          messageId: 1n,
          userId: BigInt(user.id),
        },
      },
    })

    const result = await getUpdates(
      {
        bucket: {
          type: {
            oneofKind: "chat",
            chat: {
              peerId: {
                type: {
                  oneofKind: "chat",
                  chat: { chatId: BigInt(chat.id) },
                },
              },
            },
          },
        },
        startSeq: 0n,
        seqEnd: 0n,
        totalLimit: 1000,
        limit: 0,
      },
      { currentUserId: user.id } as any,
    )

    expect(result.seq).toBe(2n)
    expect(result.final).toBe(true)
    expect(result.updates.map((update) => update.update.oneofKind)).toEqual([
      "chatSkipPts",
      "chatSkipPts",
    ])
  })

  test("advances over missing editMessage targets with chatSkipPts", async () => {
    const { users, space } = await testUtils.createSpaceWithMembers("Missing Edit Update", ["missing-edit@example.com"])
    const user = users[0]
    if (!user || !space) throw new Error("Fixture creation failed")

    const chat = await testUtils.createChat(space.id, "Missing Edit Chat", "thread", true)
    if (!chat) throw new Error("Chat creation failed")

    await insertServerUpdate({
      bucket: UpdateBucket.Chat,
      entityId: chat.id,
      seq: 1,
      payload: {
        oneofKind: "editMessage",
        editMessage: {
          chatId: BigInt(chat.id),
          msgId: 1n,
        },
      },
    })
    await db.insert(messages).values({
      chatId: chat.id,
      messageId: 2,
      fromId: user.id,
      text: "valid after missing edit",
    })
    await insertServerUpdate({
      bucket: UpdateBucket.Chat,
      entityId: chat.id,
      seq: 2,
      payload: {
        oneofKind: "newMessage",
        newMessage: {
          chatId: BigInt(chat.id),
          msgId: 2n,
        },
      },
    })

    const inputPeer: InputPeer = {
      type: {
        oneofKind: "chat",
        chat: { chatId: BigInt(chat.id) },
      },
    }

    const result = await getUpdates(
      {
        bucket: {
          type: {
            oneofKind: "chat",
            chat: { peerId: inputPeer },
          },
        },
        startSeq: 0n,
        seqEnd: 0n,
        totalLimit: 1000,
        limit: 0,
      },
      { currentUserId: user.id } as any,
    )

    expect(result.seq).toBe(2n)
    expect(result.final).toBe(true)
    expect(result.resultType).toBe(GetUpdatesResult_ResultType.SLICE)
    expect(result.updates.map((update) => update.update.oneofKind)).toEqual(["chatSkipPts", "newMessage"])
  })

  test("advances over skippable chat updates with chatSkipPts", async () => {
    const { users, space } = await testUtils.createSpaceWithMembers("Skippable Chat Update", ["skip@example.com"])
    const user = users[0]
    if (!user || !space) throw new Error("Fixture creation failed")

    const chat = await testUtils.createChat(space.id, "Skip Chat", "thread", true)
    if (!chat) throw new Error("Chat creation failed")

    await insertServerUpdate({
      bucket: UpdateBucket.Chat,
      entityId: chat.id,
      seq: 1,
      payload: {
        oneofKind: "userChatParticipantDelete",
        userChatParticipantDelete: {
          chatId: BigInt(chat.id),
        },
      },
    })
    await db.insert(messages).values({
      chatId: chat.id,
      messageId: 2,
      fromId: user.id,
      text: "valid after skippable update",
    })
    await insertServerUpdate({
      bucket: UpdateBucket.Chat,
      entityId: chat.id,
      seq: 2,
      payload: {
        oneofKind: "newMessage",
        newMessage: {
          chatId: BigInt(chat.id),
          msgId: 2n,
        },
      },
    })

    const result = await getUpdates(
      {
        bucket: {
          type: {
            oneofKind: "chat",
            chat: {
              peerId: {
                type: {
                  oneofKind: "chat",
                  chat: { chatId: BigInt(chat.id) },
                },
              },
            },
          },
        },
        startSeq: 0n,
        seqEnd: 0n,
        totalLimit: 1000,
        limit: 0,
      },
      { currentUserId: user.id } as any,
    )

    expect(result.seq).toBe(2n)
    expect(result.final).toBe(true)
    expect(result.resultType).toBe(GetUpdatesResult_ResultType.SLICE)
    expect(result.updates.map((update) => update.update.oneofKind)).toEqual(["chatSkipPts", "newMessage"])
  })

  test("returns required sidecars for chat message catch-up", async () => {
    const { users, space } = await testUtils.createSpaceWithMembers("Sidecar Updates", [
      "sidecar-sender@example.com",
      "sidecar-viewer@example.com",
    ])
    const sender = users[0]
    const viewer = users[1]
    if (!sender || !viewer || !space) throw new Error("Fixture creation failed")

    const parentChat = await testUtils.createChat(space.id, "Sidecar Parent Thread", "thread", true)
    if (!parentChat) throw new Error("Parent chat creation failed")
    const chat = await testUtils.createChat(space.id, "Sidecar Thread", "thread", true)
    if (!chat) throw new Error("Chat creation failed")
    await db.insert(messages).values({
      chatId: parentChat.id,
      messageId: 1,
      fromId: sender.id,
      text: "parent anchor",
    })
    await db
      .update(chats)
      .set({ parentChatId: parentChat.id, parentMessageId: 1 })
      .where(eq(chats.id, chat.id))
    const forwardedChat = await testUtils.createChat(space.id, "Forwarded Source", "thread", false)
    if (!forwardedChat) throw new Error("Forwarded chat creation failed")
    await testUtils.addParticipant(chat.id, sender.id)
    await testUtils.addParticipant(chat.id, viewer.id)
    await db.insert(dialogs).values({
      userId: viewer.id,
      chatId: chat.id,
      spaceId: space.id,
      readInboxMaxId: 0,
    })

    await db.insert(messages).values({
      chatId: chat.id,
      messageId: 1,
      fromId: sender.id,
      text: "hello from sidecar test",
      fwdFromPeerChatId: forwardedChat.id,
      fwdFromMessageId: 99,
      fwdFromSenderId: sender.id,
    })

    await insertServerUpdate({
      bucket: UpdateBucket.Chat,
      entityId: chat.id,
      seq: 1,
      payload: {
        oneofKind: "newMessage",
        newMessage: {
          chatId: BigInt(chat.id),
          msgId: 1n,
        },
      },
    })

    const result = await getUpdates(
      {
        bucket: {
          type: {
            oneofKind: "chat",
            chat: {
              peerId: {
                type: {
                  oneofKind: "chat",
                  chat: { chatId: BigInt(chat.id) },
                },
              },
            },
          },
        },
        startSeq: 0n,
        seqEnd: 0n,
        totalLimit: 1000,
        limit: 0,
      },
      { currentUserId: viewer.id } as any,
    )

    expect(result.resultType).toBe(GetUpdatesResult_ResultType.SLICE)
    expect(result.final).toBe(true)
    expect(result.seq).toBe(1n)
    expect(result.updates).toHaveLength(1)
    expect(result.updates[0]?.update.oneofKind).toBe("newMessage")

    const sidecarChatIds = result.sidecars?.chats.map((sidecar) => sidecar.id) ?? []
    expect(sidecarChatIds).toContain(BigInt(parentChat.id))
    expect(sidecarChatIds).toContain(BigInt(chat.id))
    expect(sidecarChatIds).not.toContain(BigInt(forwardedChat.id))
    expect(sidecarChatIds.indexOf(BigInt(parentChat.id))).toBeLessThan(sidecarChatIds.indexOf(BigInt(chat.id)))
    expect(result.sidecars?.spaces.map((sidecar) => sidecar.id)).toContain(BigInt(space.id))
    const senderSidecar = result.sidecars?.users.find((user) => user.id === BigInt(sender.id))
    expect(senderSidecar).toBeDefined()
    expect(senderSidecar?.min).toBe(true)
    expect(senderSidecar?.email).toBeUndefined()
    const dialogSidecar = result.sidecars?.dialogs.find((dialog) => dialog.chatId === BigInt(chat.id))
    expect(dialogSidecar).toBeDefined()
    expect(dialogSidecar?.unreadCount).toBe(1)
    expect(result.sidecars?.dialogs.map((dialog) => dialog.chatId)).not.toContain(BigInt(parentChat.id))
  })

  test("does not disclose an inaccessible parent through chat-bucket sidecars", async () => {
    const { users, space } = await testUtils.createSpaceWithMembers("Private Parent Sidecars", [
      "private-parent-owner@example.com",
      "private-parent-viewer@example.com",
    ])
    const owner = users[0]
    const viewer = users[1]
    if (!owner || !viewer || !space) throw new Error("Fixture creation failed")

    const parentChat = await testUtils.createChat(
      space.id,
      "Inaccessible Private Parent",
      "thread",
      false,
      owner.id,
    )
    const childChat = await testUtils.createChat(
      space.id,
      "Accessible Private Child",
      "thread",
      false,
      owner.id,
    )
    if (!parentChat || !childChat) throw new Error("Chat creation failed")
    await testUtils.addParticipant(childChat.id, viewer.id)
    await db.insert(messages).values({
      chatId: parentChat.id,
      messageId: 1,
      fromId: owner.id,
      text: "private parent anchor",
    })
    await db
      .update(chats)
      .set({ parentChatId: parentChat.id, parentMessageId: 1 })
      .where(eq(chats.id, childChat.id))
    await db.insert(messages).values({
      chatId: childChat.id,
      messageId: 1,
      fromId: owner.id,
      text: "accessible child message",
    })
    await insertServerUpdate({
      bucket: UpdateBucket.Chat,
      entityId: childChat.id,
      seq: 1,
      payload: {
        oneofKind: "newMessage",
        newMessage: { chatId: BigInt(childChat.id), msgId: 1n },
      },
    })

    const result = await getUpdates({
      bucket: {
        type: {
          oneofKind: "chat",
          chat: {
            peerId: {
              type: { oneofKind: "chat", chat: { chatId: BigInt(childChat.id) } },
            },
          },
        },
      },
      startSeq: 0n,
      seqEnd: 0n,
      totalLimit: 1000,
      limit: 10,
    }, { currentUserId: viewer.id } as any)

    const sidecarChatIds = result.sidecars?.chats.map((chat) => Number(chat.id)) ?? []
    expect(sidecarChatIds).toContain(childChat.id)
    expect(sidecarChatIds).not.toContain(parentChat.id)
    expect(result.sidecars?.spaces.map((sidecar) => Number(sidecar.id))).toEqual([space.id])
  })

  test("returns sidecars only for the delivered page", async () => {
    const { users, space } = await testUtils.createSpaceWithMembers("Prefix Sidecars", [
      "prefix-one@example.com",
      "prefix-two@example.com",
      "prefix-viewer@example.com",
    ])
    const firstSender = users[0]
    const withheldSender = users[1]
    const viewer = users[2]
    if (!firstSender || !withheldSender || !viewer || !space) throw new Error("Fixture creation failed")

    const chat = await testUtils.createChat(space.id, "Prefix Thread", "thread", true)
    if (!chat) throw new Error("Chat creation failed")
    await testUtils.addParticipant(chat.id, firstSender.id)
    await testUtils.addParticipant(chat.id, withheldSender.id)
    await testUtils.addParticipant(chat.id, viewer.id)

    await db.insert(messages).values({
      chatId: chat.id,
      messageId: 1,
      fromId: firstSender.id,
      text: "delivered",
    })
    await db.insert(messages).values({
      chatId: chat.id,
      messageId: 3,
      fromId: withheldSender.id,
      text: "inflated but withheld behind page boundary",
    })

    await insertServerUpdate({
      bucket: UpdateBucket.Chat,
      entityId: chat.id,
      seq: 1,
      payload: {
        oneofKind: "newMessage",
        newMessage: {
          chatId: BigInt(chat.id),
          msgId: 1n,
        },
      },
    })
    await insertServerUpdate({
      bucket: UpdateBucket.Chat,
      entityId: chat.id,
      seq: 2,
      payload: {
        oneofKind: "newMessage",
        newMessage: {
          chatId: BigInt(chat.id),
          msgId: 2n,
        },
      },
    })
    await insertServerUpdate({
      bucket: UpdateBucket.Chat,
      entityId: chat.id,
      seq: 3,
      payload: {
        oneofKind: "newMessage",
        newMessage: {
          chatId: BigInt(chat.id),
          msgId: 3n,
        },
      },
    })

    const result = await getUpdates(
      {
        bucket: {
          type: {
            oneofKind: "chat",
            chat: {
              peerId: {
                type: {
                  oneofKind: "chat",
                  chat: { chatId: BigInt(chat.id) },
                },
              },
            },
          },
        },
        startSeq: 0n,
        seqEnd: 0n,
        totalLimit: 1000,
        limit: 1,
      },
      { currentUserId: viewer.id } as any,
    )

    expect(result.seq).toBe(1n)
    expect(result.final).toBe(false)
    expect(result.updates).toHaveLength(1)
    expect(result.updates[0]?.update.oneofKind).toBe("newMessage")

    expect(result.sidecars?.users.map((user) => user.id)).toContain(BigInt(firstSender.id))
    expect(result.sidecars?.users.map((user) => user.id)).not.toContain(BigInt(withheldSender.id))
  })

  test("inflates userReadMaxId to updateReadMaxId in user bucket", async () => {
    const user = await testUtils.createUser("read-max@example.com")

    await insertServerUpdate({
      bucket: UpdateBucket.User,
      entityId: user.id,
      seq: 1,
      payload: {
        oneofKind: "userReadMaxId",
        userReadMaxId: {
          peerId: {
            type: {
              oneofKind: "chat",
              chat: { chatId: 123n },
            },
          },
          readMaxId: 42n,
          unreadCount: 3,
        },
      },
    })

    const result = await getUpdates(
      {
        bucket: { type: { oneofKind: "user", user: {} } },
        startSeq: 0n,
        seqEnd: 0n,
        totalLimit: 1000,
        limit: 0,
      },
      { currentUserId: user.id } as any,
    )

    expect(result.resultType).toBe(GetUpdatesResult_ResultType.SLICE)
    expect(result.final).toBe(true)
    expect(Number(result.seq)).toBe(1)
    expect(result.updates).toHaveLength(1)
    const first = result.updates[0]
    expect(first).toBeDefined()
    if (!first) throw new Error("Missing first update")
    expect(first.update.oneofKind).toBe("updateReadMaxId")
    if (first.update.oneofKind !== "updateReadMaxId") throw new Error("Unexpected update type")
    expect(first.update.updateReadMaxId.readMaxId).toBe(42n)
    expect(first.update.updateReadMaxId.unreadCount).toBe(3)
  })

  test("includes Chat and Dialog sidecars only for the delivered user-read page's referenced DM pairs", async () => {
    const lowerPeer = await testUtils.createUser("dm-read-lower@example.com")
    const viewer = await testUtils.createUser("dm-read-viewer@example.com")
    const higherPeer = await testUtils.createUser("dm-read-higher@example.com")
    const withheldPeer = await testUtils.createUser("dm-read-withheld@example.com")
    const lowerChat = await testUtils.createPrivateChat(viewer, lowerPeer)
    const higherChat = await testUtils.createPrivateChat(viewer, higherPeer)
    const withheldChat = await testUtils.createPrivateChat(viewer, withheldPeer)
    const foreignChat = await testUtils.createPrivateChat(lowerPeer, higherPeer)
    if (!lowerChat || !higherChat || !withheldChat || !foreignChat) throw new Error("Missing DM read fixtures")
    await db.insert(dialogs).values([
      { chatId: lowerChat.id, userId: viewer.id, peerUserId: lowerPeer.id, readInboxMaxId: 7 },
      { chatId: higherChat.id, userId: viewer.id, peerUserId: higherPeer.id, readInboxMaxId: 9 },
      { chatId: withheldChat.id, userId: viewer.id, peerUserId: withheldPeer.id, readInboxMaxId: 11 },
    ])
    const peers = [lowerPeer, higherPeer, lowerPeer, withheldPeer]
    for (const [index, peer] of peers.entries()) {
      await insertServerUpdate({
        bucket: UpdateBucket.User,
        entityId: viewer.id,
        seq: index + 1,
        payload: { oneofKind: "userReadMaxId", userReadMaxId: {
          peerId: { type: { oneofKind: "user", user: { userId: BigInt(peer.id) } } },
          readMaxId: 7n,
          unreadCount: 0,
        } },
      })
    }
    const result = await getUpdates({
      bucket: { type: { oneofKind: "user", user: {} } },
      startSeq: 0n, seqEnd: 0n, totalLimit: 0, limit: 3,
    }, { currentUserId: viewer.id } as any)
    expect(result.seq).toBe(3n)
    expect(result.final).toBe(false)
    expect(result.sidecars?.chats.map((chat) => Number(chat.id)).sort((a, b) => a - b)).toEqual([lowerChat.id, higherChat.id].sort((a, b) => a - b))
    expect(result.sidecars?.dialogs.map((dialog) => Number(dialog.chatId)).sort((a, b) => a - b)).toEqual([lowerChat.id, higherChat.id].sort((a, b) => a - b))
    expect(result.sidecars?.dialogs.find((dialog) => dialog.chatId === BigInt(lowerChat.id))?.readMaxId).toBe(7n)
    expect(result.sidecars?.dialogs.find((dialog) => dialog.chatId === BigInt(higherChat.id))?.readMaxId).toBe(9n)
    expect(result.sidecars?.chats.some((chat) => chat.id === BigInt(foreignChat.id) || chat.id === BigInt(withheldChat.id))).toBe(false)
  })

  test("inflates userMarkAsUnread to markAsUnread in user bucket", async () => {
    const user = await testUtils.createUser("unread-mark@example.com")

    await insertServerUpdate({
      bucket: UpdateBucket.User,
      entityId: user.id,
      seq: 1,
      payload: {
        oneofKind: "userMarkAsUnread",
        userMarkAsUnread: {
          peerId: {
            type: {
              oneofKind: "chat",
              chat: { chatId: 123n },
            },
          },
          unreadMark: true,
        },
      },
    })

    const result = await getUpdates(
      {
        bucket: { type: { oneofKind: "user", user: {} } },
        startSeq: 0n,
        seqEnd: 0n,
        totalLimit: 1000,
        limit: 0,
      },
      { currentUserId: user.id } as any,
    )

    expect(result.resultType).toBe(GetUpdatesResult_ResultType.SLICE)
    expect(result.final).toBe(true)
    expect(Number(result.seq)).toBe(1)
    expect(result.updates).toHaveLength(1)
    const first = result.updates[0]
    expect(first).toBeDefined()
    if (!first) throw new Error("Missing first update")
    expect(first.update.oneofKind).toBe("markAsUnread")
    if (first.update.oneofKind !== "markAsUnread") throw new Error("Unexpected update type")
    expect(first.update.markAsUnread.unreadMark).toBe(true)
  })


  test("inflates userDialogNotificationSettings to dialogNotificationSettings in user bucket", async () => {
    const user = await testUtils.createUser("dialog-settings@sync.com")

    await insertServerUpdate({
      bucket: UpdateBucket.User,
      entityId: user.id,
      seq: 1,
      payload: {
        oneofKind: "userDialogNotificationSettings",
        userDialogNotificationSettings: {
          peerId: {
            type: {
              oneofKind: "chat",
              chat: { chatId: 123n },
            },
          },
          notificationSettings: {
            mode: DialogNotificationSettings_Mode.MENTIONS,
          },
        },
      },
    })

    const result = await getUpdates(
      {
        bucket: { type: { oneofKind: "user", user: {} } },
        startSeq: 0n,
        seqEnd: 0n,
        totalLimit: 1000,
        limit: 0,
      },
      { currentUserId: user.id } as any,
    )

    expect(result.resultType).toBe(GetUpdatesResult_ResultType.SLICE)
    expect(result.final).toBe(true)
    expect(Number(result.seq)).toBe(1)
    expect(result.updates).toHaveLength(1)
    const first = result.updates[0]
    expect(first).toBeDefined()
    if (!first) throw new Error("Missing first update")
    expect(first.update.oneofKind).toBe("dialogNotificationSettings")
    if (first.update.oneofKind !== "dialogNotificationSettings") throw new Error("Unexpected update type")
    expect(first.update.dialogNotificationSettings.notificationSettings?.mode).toBe(
      DialogNotificationSettings_Mode.MENTIONS,
    )
  })

  test("inflates updatedUser in user bucket", async () => {
    const user = await testUtils.createUser("updated-user@sync.com")

    await insertServerUpdate({
      bucket: UpdateBucket.User,
      entityId: user.id,
      seq: 1,
      payload: {
        oneofKind: "updatedUser",
        updatedUser: {
          user: {
            id: BigInt(user.id),
            firstName: "Updated",
            lastName: "User",
            username: "updateduser",
            bio: "Profile bio",
          },
        },
      },
    })

    const result = await getUpdates(
      {
        bucket: { type: { oneofKind: "user", user: {} } },
        startSeq: 0n,
        seqEnd: 0n,
        totalLimit: 1000,
        limit: 0,
      },
      { currentUserId: user.id } as any,
    )

    expect(result.resultType).toBe(GetUpdatesResult_ResultType.SLICE)
    expect(result.final).toBe(true)
    expect(Number(result.seq)).toBe(1)
    expect(result.updates).toHaveLength(1)
    const first = result.updates[0]
    expect(first).toBeDefined()
    if (!first) throw new Error("Missing first update")
    expect(first.update.oneofKind).toBe("updatedUser")
    if (first.update.oneofKind !== "updatedUser") throw new Error("Unexpected update type")
    const updatedUser = first.update.updatedUser.user
    expect(updatedUser).toBeDefined()
    if (!updatedUser) throw new Error("Expected updated user")
    expect(updatedUser.id).toBe(BigInt(user.id))
    expect(updatedUser.firstName).toBe("Updated")
    expect(updatedUser.bio).toBe("Profile bio")
  })

  test("inflates user settings in the user bucket", async () => {
    const user = await testUtils.createUser("settings-sync@sync.com")
    const settings = Encoders.userSettings({
      general: {
        notifications: { mode: UserSettingsNotificationsMode.All, silent: false, disableDmNotifications: false },
        privacy: { shareTimeZone: false, appearInGlobalSearch: true },
        compose: { replacePastedLinksWithTitles: true },
      },
    })

    await insertServerUpdate({
      bucket: UpdateBucket.User,
      entityId: user.id,
      seq: 1,
      payload: {
        oneofKind: "userSettings",
        userSettings: { settings },
      },
    })

    const result = await getUpdates(
      {
        bucket: { type: { oneofKind: "user", user: {} } },
        startSeq: 0n,
        seqEnd: 0n,
        totalLimit: 1000,
        limit: 0,
      },
      { currentUserId: user.id } as any,
    )

    expect(result.resultType).toBe(GetUpdatesResult_ResultType.SLICE)
    expect(result.final).toBe(true)
    expect(Number(result.seq)).toBe(1)
    expect(result.updates).toHaveLength(1)
    const first = result.updates[0]
    expect(first).toBeDefined()
    if (!first) throw new Error("Missing first update")
    expect(first.update.oneofKind).toBe("updateUserSettings")
    if (first.update.oneofKind !== "updateUserSettings") throw new Error("Unexpected update type")
    expect(first.update.updateUserSettings.settings).toEqual(settings)
  })

  test("integration: readMessages persists userReadMaxId and getUpdates inflates updateReadMaxId", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("ReadState Integration", ["readstate@sync.com"])
    const user = users[0]
    if (!space || !user) throw new Error("Fixture creation failed")

    const chat = await testUtils.createChat(space.id, "ReadState Thread", "thread", true)
    if (!chat) throw new Error("Chat creation failed")

    await db.insert(dialogs).values({ userId: user.id, chatId: chat.id, spaceId: space.id }).execute()

    const [beforeRow] = await db
      .select()
      .from(updates)
      .where(and(eq(updates.bucket, UpdateBucket.User), eq(updates.entityId, user.id)))
      .orderBy(desc(updates.seq))
      .limit(1)

    const beforeSeq = beforeRow?.seq ?? 0

    await readMessages(
      { peerThreadId: chat.id.toString(), maxId: 1 },
      { currentUserId: user.id, currentSessionId: 1, ip: undefined },
    )

    const result = await getUpdates(
      {
        bucket: { type: { oneofKind: "user", user: {} } },
        startSeq: BigInt(beforeSeq),
        seqEnd: 0n,
        totalLimit: 1000,
        limit: 0,
      },
      { currentUserId: user.id } as any,
    )

    expect(result.resultType).toBe(GetUpdatesResult_ResultType.SLICE)
    expect(result.final).toBe(true)
    expect(Number(result.seq)).toBe(beforeSeq + 1)
    expect(result.updates.length).toBe(1)
    const first = result.updates[0]
    expect(first).toBeDefined()
    if (!first) throw new Error("Missing first update")
    expect(first.update.oneofKind).toBe("updateReadMaxId")
    if (first.update.oneofKind !== "updateReadMaxId") throw new Error("Unexpected update type")
    expect(first.update.updateReadMaxId.readMaxId).toBe(1n)
    expect(first.update.updateReadMaxId.unreadCount).toBe(0)

    const peerType = first.update.updateReadMaxId.peerId?.type
    if (!peerType || peerType.oneofKind !== "chat") throw new Error("Expected chat peer for thread")
    expect(peerType.chat.chatId).toBe(BigInt(chat.id))
  })

  test("readMessages does not regress readInboxMaxId when called with a stale smaller maxId", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("ReadState No Regress", ["noregress@sync.com"])
    const user = users[0]
    if (!space || !user) throw new Error("Fixture creation failed")

    const chat = await testUtils.createChat(space.id, "No Regress Thread", "thread", true)
    if (!chat) throw new Error("Chat creation failed")

    await db
      .insert(dialogs)
      .values({ userId: user.id, chatId: chat.id, spaceId: space.id, readInboxMaxId: 10, unreadMark: false })
      .execute()

    const [beforeRow] = await db
      .select()
      .from(updates)
      .where(and(eq(updates.bucket, UpdateBucket.User), eq(updates.entityId, user.id)))
      .orderBy(desc(updates.seq))
      .limit(1)
    const beforeSeq = beforeRow?.seq ?? 0

    await readMessages(
      { peerThreadId: chat.id.toString(), maxId: 1 },
      { currentUserId: user.id, currentSessionId: 1, ip: undefined },
    )

    const [dialogRow] = await db
      .select({ readInboxMaxId: dialogs.readInboxMaxId, unreadMark: dialogs.unreadMark })
      .from(dialogs)
      .where(and(eq(dialogs.chatId, chat.id), eq(dialogs.userId, user.id)))
      .limit(1)

    expect(dialogRow?.readInboxMaxId).toBe(10)
    expect(dialogRow?.unreadMark).toBe(false)

    const [afterRow] = await db
      .select()
      .from(updates)
      .where(and(eq(updates.bucket, UpdateBucket.User), eq(updates.entityId, user.id)))
      .orderBy(desc(updates.seq))
      .limit(1)
    const afterSeq = afterRow?.seq ?? 0
    expect(afterSeq).toBe(beforeSeq)
  })

  test("readMessages clears unreadMark without regressing readInboxMaxId when maxId is stale", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("ReadState Clear Mark", ["clearmark@sync.com"])
    const user = users[0]
    if (!space || !user) throw new Error("Fixture creation failed")

    const chat = await testUtils.createChat(space.id, "Clear Mark Thread", "thread", true)
    if (!chat) throw new Error("Chat creation failed")

    await db
      .insert(dialogs)
      .values({ userId: user.id, chatId: chat.id, spaceId: space.id, readInboxMaxId: 10, unreadMark: true })
      .execute()

    const [beforeRow] = await db
      .select()
      .from(updates)
      .where(and(eq(updates.bucket, UpdateBucket.User), eq(updates.entityId, user.id)))
      .orderBy(desc(updates.seq))
      .limit(1)
    const beforeSeq = beforeRow?.seq ?? 0

    await readMessages(
      { peerThreadId: chat.id.toString(), maxId: 1 },
      { currentUserId: user.id, currentSessionId: 1, ip: undefined },
    )

    const [dialogRow] = await db
      .select({ readInboxMaxId: dialogs.readInboxMaxId, unreadMark: dialogs.unreadMark })
      .from(dialogs)
      .where(and(eq(dialogs.chatId, chat.id), eq(dialogs.userId, user.id)))
      .limit(1)

    expect(dialogRow?.readInboxMaxId).toBe(10)
    expect(dialogRow?.unreadMark).toBe(false)

    const [afterRow] = await db
      .select()
      .from(updates)
      .where(and(eq(updates.bucket, UpdateBucket.User), eq(updates.entityId, user.id)))
      .orderBy(desc(updates.seq))
      .limit(1)

    expect(afterRow).toBeTruthy()
    expect(afterRow!.seq).toBeGreaterThan(beforeSeq)

    const decrypted = UpdatesModel.decrypt(afterRow!)
    expect(decrypted.payload.update.oneofKind).toBe("userMarkAsUnread")
    if (decrypted.payload.update.oneofKind === "userMarkAsUnread") {
      expect(decrypted.payload.update.userMarkAsUnread.unreadMark).toBe(false)
    }
  })
})
