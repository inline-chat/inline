import { describe, expect, test } from "bun:test"
import { and, desc, eq } from "drizzle-orm"
import {
  DialogNotificationSettings_Mode,
  type InputPeer,
} from "@inline-chat/protocol/core"
import { setupTestLifecycle, testUtils } from "../setup"
import { db } from "@in/server/db"
import { chats, dialogs, messages, updates, UpdateBucket, users } from "@in/server/db/schema"
import { updateDialogNotificationSettings } from "@in/server/functions/messages.updateDialogNotificationSettings"
import { decodeDialogNotificationSettings } from "@in/server/modules/notifications/dialogNotificationSettings"

describe("updateDialogNotificationSettings", () => {
  setupTestLifecycle()

  test("sets dialog notification settings and emits updates", async () => {
    const userA = await testUtils.createUser("dialog-notif-a@example.com")
    const userB = await testUtils.createUser("dialog-notif-b@example.com")
    const { chat } = await testUtils.createPrivateChatWithOptionalDialog({
      userA,
      userB,
      createDialogForUserA: true,
      createDialogForUserB: false,
    })

    const peerId: InputPeer = {
      type: {
        oneofKind: "user",
        user: { userId: BigInt(userB.id) },
      },
    }

    const result = await updateDialogNotificationSettings(
      {
        peerId,
        notificationSettings: {
          mode: DialogNotificationSettings_Mode.MENTIONS,
        },
      },
      {
        currentUserId: userA.id,
        currentSessionId: 1,
      },
    )

    expect(result.updates).toHaveLength(1)
    expect(result.updates[0]?.update.oneofKind).toBe("dialogNotificationSettings")

    const [dialogRow] = await db
      .select({ notificationSettings: dialogs.notificationSettings })
      .from(dialogs)
      .where(and(eq(dialogs.chatId, chat.id), eq(dialogs.userId, userA.id)))
      .limit(1)
    expect(dialogRow).toBeDefined()
    const decoded = decodeDialogNotificationSettings(dialogRow?.notificationSettings)
    expect(decoded?.mode).toBe(DialogNotificationSettings_Mode.MENTIONS)

    const [latestUserUpdate] = await db
      .select()
      .from(updates)
      .where(and(eq(updates.bucket, UpdateBucket.User), eq(updates.entityId, userA.id)))
      .orderBy(desc(updates.seq))
      .limit(1)
    expect(latestUserUpdate).toBeDefined()
  })

  test("setting All follows and shows a thread without undoing the follow later", async () => {
    const user = await testUtils.createUser("dialog-notif-all-follow@example.com")
    const chat = await testUtils.createChat(null, "Engineering", "thread", false, user.id)
    if (!chat) throw new Error("Thread chat not created")

    await testUtils.addParticipant(chat.id, user.id)
    await db.insert(dialogs).values({
      chatId: chat.id,
      userId: user.id,
      followMode: "unfollowed",
      chatListHidden: true,
      open: false,
      archived: true,
    })

    const peerId: InputPeer = {
      type: {
        oneofKind: "chat",
        chat: { chatId: BigInt(chat.id) },
      },
    }

    const allResult = await updateDialogNotificationSettings(
      {
        peerId,
        notificationSettings: {
          mode: DialogNotificationSettings_Mode.ALL,
        },
      },
      testUtils.functionContext({ userId: user.id, sessionId: 1 }),
    )

    expect(allResult.updates.map((update) => update.update.oneofKind)).toEqual([
      "dialogNotificationSettings",
      "dialogFollowMode",
      "chatOpen",
    ])

    let [dialogRow] = await db
      .select()
      .from(dialogs)
      .where(and(eq(dialogs.chatId, chat.id), eq(dialogs.userId, user.id)))
      .limit(1)

    expect(decodeDialogNotificationSettings(dialogRow?.notificationSettings)?.mode).toBe(
      DialogNotificationSettings_Mode.ALL,
    )
    expect(dialogRow?.followMode).toBe("following")
    expect(dialogRow?.chatListHidden).toBeNull()
    expect(dialogRow?.open).toBe(true)
    expect(dialogRow?.order).toBeTruthy()
    expect(dialogRow?.archived).toBe(false)

    const mentionsResult = await updateDialogNotificationSettings(
      {
        peerId,
        notificationSettings: {
          mode: DialogNotificationSettings_Mode.MENTIONS,
        },
      },
      testUtils.functionContext({ userId: user.id, sessionId: 1 }),
    )

    expect(mentionsResult.updates.map((update) => update.update.oneofKind)).toEqual([
      "dialogNotificationSettings",
    ])

    ;[dialogRow] = await db
      .select()
      .from(dialogs)
      .where(and(eq(dialogs.chatId, chat.id), eq(dialogs.userId, user.id)))
      .limit(1)

    expect(dialogRow?.followMode).toBe("following")
    expect(dialogRow?.open).toBe(true)
  })

  test("clears dialog notification settings to inherit global", async () => {
    const userA = await testUtils.createUser("dialog-notif-clear-a@example.com")
    const userB = await testUtils.createUser("dialog-notif-clear-b@example.com")
    const { chat } = await testUtils.createPrivateChatWithOptionalDialog({
      userA,
      userB,
      createDialogForUserA: true,
      createDialogForUserB: false,
    })

    const peerId: InputPeer = {
      type: {
        oneofKind: "user",
        user: { userId: BigInt(userB.id) },
      },
    }

    await updateDialogNotificationSettings(
      {
        peerId,
        notificationSettings: {
          mode: DialogNotificationSettings_Mode.NONE,
        },
      },
      {
        currentUserId: userA.id,
        currentSessionId: 1,
      },
    )

    const result = await updateDialogNotificationSettings(
      {
        peerId,
      },
      {
        currentUserId: userA.id,
        currentSessionId: 1,
      },
    )

    expect(result.updates).toHaveLength(1)

    const [dialogRow] = await db
      .select({ notificationSettings: dialogs.notificationSettings })
      .from(dialogs)
      .where(and(eq(dialogs.chatId, chat.id), eq(dialogs.userId, userA.id)))
      .limit(1)
    expect(dialogRow?.notificationSettings ?? null).toBe(null)
  })

  test("returns no-op when value is unchanged", async () => {
    const userA = await testUtils.createUser("dialog-notif-noop-a@example.com")
    const userB = await testUtils.createUser("dialog-notif-noop-b@example.com")
    const { chat } = await testUtils.createPrivateChatWithOptionalDialog({
      userA,
      userB,
      createDialogForUserA: true,
      createDialogForUserB: false,
    })

    const peerId: InputPeer = {
      type: {
        oneofKind: "user",
        user: { userId: BigInt(userB.id) },
      },
    }

    await updateDialogNotificationSettings(
      {
        peerId,
        notificationSettings: {
          mode: DialogNotificationSettings_Mode.ALL,
        },
      },
      {
        currentUserId: userA.id,
        currentSessionId: 1,
      },
    )

    const [before] = await db
      .select({ seq: updates.seq })
      .from(updates)
      .where(and(eq(updates.bucket, UpdateBucket.User), eq(updates.entityId, userA.id)))
      .orderBy(desc(updates.seq))
      .limit(1)

    const result = await updateDialogNotificationSettings(
      {
        peerId,
        notificationSettings: {
          mode: DialogNotificationSettings_Mode.ALL,
        },
      },
      {
        currentUserId: userA.id,
        currentSessionId: 1,
      },
    )

    const [after] = await db
      .select({ seq: updates.seq })
      .from(updates)
      .where(and(eq(updates.bucket, UpdateBucket.User), eq(updates.entityId, userA.id)))
      .orderBy(desc(updates.seq))
      .limit(1)

    expect(result.updates).toHaveLength(0)
    expect(after?.seq).toBe(before?.seq)
    const [dialogRow] = await db
      .select({ notificationSettings: dialogs.notificationSettings })
      .from(dialogs)
      .where(and(eq(dialogs.chatId, chat.id), eq(dialogs.userId, userA.id)))
      .limit(1)
    expect(dialogRow?.notificationSettings).toBeDefined()
  })

  test("keeps user-before-dialog lock order with concurrent dialog mutations", async () => {
    const userA = await testUtils.createUser("dialog-notif-lock-order-a@example.com")
    const userB = await testUtils.createUser("dialog-notif-lock-order-b@example.com")
    const { chat } = await testUtils.createPrivateChatWithOptionalDialog({
      userA,
      userB,
      createDialogForUserA: true,
      createDialogForUserB: false,
    })
    const peerId: InputPeer = {
      type: { oneofKind: "user", user: { userId: BigInt(userB.id) } },
    }
    let releaseOwner!: () => void
    const ownerCanContinue = new Promise<void>((resolve) => { releaseOwner = resolve })
    let ownerLocked!: () => void
    const ownerHasUserLock = new Promise<void>((resolve) => { ownerLocked = resolve })
    const owner = db.transaction(async (tx) => {
      await tx.select({ id: users.id }).from(users).where(eq(users.id, userA.id)).for("update").limit(1)
      ownerLocked()
      await ownerCanContinue
      await tx
        .select({ id: dialogs.id })
        .from(dialogs)
        .where(and(eq(dialogs.chatId, chat.id), eq(dialogs.userId, userA.id)))
        .for("update")
        .limit(1)
    })
    await ownerHasUserLock

    const notification = updateDialogNotificationSettings(
      {
        peerId,
        notificationSettings: { mode: DialogNotificationSettings_Mode.MENTIONS },
      },
      testUtils.functionContext({ userId: userA.id, sessionId: 1 }),
    )
    await Bun.sleep(25)
    releaseOwner()

    await expect(Promise.all([owner, notification])).resolves.toBeDefined()
  })

  test("returns no-op when clearing with no dialog row", async () => {
    const userA = await testUtils.createUser("dialog-notif-global-no-row-a@example.com")
    const userB = await testUtils.createUser("dialog-notif-global-no-row-b@example.com")
    const { chat } = await testUtils.createPrivateChatWithOptionalDialog({
      userA,
      userB,
      createDialogForUserA: false,
      createDialogForUserB: false,
    })

    const peerId: InputPeer = {
      type: {
        oneofKind: "user",
        user: { userId: BigInt(userB.id) },
      },
    }

    const result = await updateDialogNotificationSettings(
      {
        peerId,
      },
      {
        currentUserId: userA.id,
        currentSessionId: 1,
      },
    )

    expect(result.updates).toHaveLength(0)

    const [dialogRow] = await db
      .select({ id: dialogs.id, notificationSettings: dialogs.notificationSettings })
      .from(dialogs)
      .where(and(eq(dialogs.chatId, chat.id), eq(dialogs.userId, userA.id)))
      .limit(1)

    expect(dialogRow).toBeUndefined()
  })

  test("creates a hidden dialog when linked subthread settings are updated", async () => {
    const owner = await testUtils.createUser("dialog-notif-thread-owner@example.com")
    const participant = await testUtils.createUser("dialog-notif-thread-participant@example.com")

    const parentChat = await testUtils.createChat(null, "Parent Thread", "thread", false, owner.id)
    if (!parentChat) throw new Error("Parent chat not created")

    await testUtils.addParticipant(parentChat.id, owner.id)
    await testUtils.addParticipant(parentChat.id, participant.id)

    await db.insert(dialogs).values([
      {
        chatId: parentChat.id,
        userId: owner.id,
      },
      {
        chatId: parentChat.id,
        userId: participant.id,
      },
    ])

    await db.insert(messages).values({
      chatId: parentChat.id,
      messageId: 1,
      fromId: owner.id,
      text: "anchor",
    })

    const [childChat] = await db
      .insert(chats)
      .values({
        type: "thread",
        title: "Re: anchor",
        publicThread: false,
        createdBy: owner.id,
        parentChatId: parentChat.id,
        parentMessageId: 1,
      })
      .returning()

    if (!childChat) throw new Error("Child chat not created")

    const result = await updateDialogNotificationSettings(
      {
        peerId: {
          type: {
            oneofKind: "chat",
            chat: { chatId: BigInt(childChat.id) },
          },
        },
        notificationSettings: {
          mode: DialogNotificationSettings_Mode.MENTIONS,
        },
      },
      {
        currentUserId: participant.id,
        currentSessionId: 1,
      },
    )

    expect(result.updates).toHaveLength(1)

    const [dialogRow] = await db
      .select({
        chatListHidden: dialogs.chatListHidden,
        notificationSettings: dialogs.notificationSettings,
      })
      .from(dialogs)
      .where(and(eq(dialogs.chatId, childChat.id), eq(dialogs.userId, participant.id)))
      .limit(1)

    expect(dialogRow?.chatListHidden).toBe(true)
    expect(decodeDialogNotificationSettings(dialogRow?.notificationSettings)?.mode).toBe(
      DialogNotificationSettings_Mode.MENTIONS,
    )
  })

  test("rejects invalid mode", async () => {
    const userA = await testUtils.createUser("dialog-notif-invalid-a@example.com")
    const userB = await testUtils.createUser("dialog-notif-invalid-b@example.com")
    await testUtils.createPrivateChatWithOptionalDialog({
      userA,
      userB,
      createDialogForUserA: true,
      createDialogForUserB: false,
    })

    const peerId: InputPeer = {
      type: {
        oneofKind: "user",
        user: { userId: BigInt(userB.id) },
      },
    }

    await expect(
      updateDialogNotificationSettings(
        {
          peerId,
          notificationSettings: {
            mode: DialogNotificationSettings_Mode.UNSPECIFIED,
          },
        },
        {
          currentUserId: userA.id,
          currentSessionId: 1,
        },
      ),
    ).rejects.toThrow()
  })
})
