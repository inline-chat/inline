import { describe, expect, test } from "bun:test"
import { and, desc, eq } from "drizzle-orm"
import {
  DialogNotificationSettings_Mode,
  type InputPeer,
} from "@inline-chat/protocol/core"
import { setupTestLifecycle, testUtils } from "../setup"
import { db } from "@in/server/db"
import { chats, dialogs, messages, updates, UpdateBucket } from "@in/server/db/schema"
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
        sidebarVisible: true,
      },
      {
        chatId: parentChat.id,
        userId: participant.id,
        sidebarVisible: true,
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
        sidebarVisible: dialogs.sidebarVisible,
        notificationSettings: dialogs.notificationSettings,
      })
      .from(dialogs)
      .where(and(eq(dialogs.chatId, childChat.id), eq(dialogs.userId, participant.id)))
      .limit(1)

    expect(dialogRow?.sidebarVisible).toBe(false)
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
