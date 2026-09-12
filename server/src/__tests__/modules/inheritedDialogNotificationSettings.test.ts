import { describe, expect, test } from "bun:test"
import { eq } from "drizzle-orm"
import { DialogNotificationSettings_Mode as Mode } from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import { chats, dialogs, messages } from "@in/server/db/schema"
import { UserSettingsNotificationsMode as GlobalMode } from "@in/server/db/models/userSettings/types"
import { decideNotification } from "@in/server/modules/notifications/decision"
import { encodeDialogNotificationSettings, resolveEffectiveNotificationMode } from "@in/server/modules/notifications/dialogNotificationSettings"
import { getInheritedDialogNotificationSettings } from "@in/server/modules/notifications/inheritedDialogNotificationSettings"
import { setupTestLifecycle, testUtils } from "../setup"

describe("inherited dialog notification settings", () => {
  setupTestLifecycle()

  test("nearest explicit ancestor governs unrelated replies, independently for each recipient", async () => {
    const owner = await testUtils.createUser("notification-owner@example.com")
    const recipient = await testUtils.createUser("notification-recipient@example.com")
    const other = await testUtils.createUser("notification-other@example.com")
    const root = await testUtils.createChat(null, "Parent", "thread", false, owner.id)
    if (!root) throw new Error("Missing root")
    const threadIds = [root.id]
    for (let i = 0; i < 2; i++) {
      const parentId = threadIds.at(-1)!
      await db.insert(messages).values({ chatId: parentId, messageId: 1, fromId: owner.id })
      const [child] = await db.insert(chats).values({
        type: "thread", parentChatId: parentId, parentMessageId: 1, createdBy: owner.id,
      }).returning()
      threadIds.push(child!.id)
    }
    const childId = threadIds[1]!
    const nestedId = threadIds[2]!
    const bytes = (mode: Mode) => Buffer.from(encodeDialogNotificationSettings({ mode })!)
    const [parentDialog] = await db.insert(dialogs).values({
      userId: recipient.id, chatId: root.id, notificationSettings: bytes(Mode.MENTIONS), archived: true,
    }).returning()
    await db.insert(dialogs).values({ userId: other.id, chatId: root.id, notificationSettings: bytes(Mode.ALL) })

    const resolve = () => getInheritedDialogNotificationSettings(nestedId, [recipient.id, other.id])
    let inherited = await resolve()
    expect(inherited.get(recipient.id)?.mode).toBe(Mode.MENTIONS)
    expect(inherited.get(other.id)?.mode).toBe(Mode.ALL)
    expect(decideNotification({
      mode: resolveEffectiveNotificationMode({ globalMode: GlobalMode.All, dialogNotificationSettings: inherited.get(recipient.id) }),
      isDM: false, isNudge: false, isUrgentNudge: false, isReplyToUser: false, isExplicitlyMentioned: false,
    }).shouldNotify).toBe(false)

    // Existing descendants see parent changes without copying or resetting child settings.
    await db.update(dialogs).set({ notificationSettings: bytes(Mode.NONE) }).where(eq(dialogs.id, parentDialog!.id))
    expect((await resolve()).get(recipient.id)?.mode).toBe(Mode.NONE)
    const [childDialog] = await db.insert(dialogs).values({
      userId: recipient.id, chatId: childId, notificationSettings: bytes(Mode.ALL),
    }).returning()
    expect((await resolve()).get(recipient.id)?.mode).toBe(Mode.ALL)
    const [nestedDialog] = await db.insert(dialogs).values({
      userId: recipient.id, chatId: nestedId, notificationSettings: bytes(Mode.NONE),
    }).returning()
    expect((await resolve()).get(recipient.id)?.mode).toBe(Mode.NONE)

    // Unknown and cleared overrides inherit; they must not mask a parent's mute.
    await db.update(dialogs).set({ notificationSettings: bytes(Mode.UNSPECIFIED) }).where(eq(dialogs.id, nestedDialog!.id))
    await db.update(dialogs).set({ notificationSettings: null }).where(eq(dialogs.id, childDialog!.id))
    expect((await resolve()).get(recipient.id)?.mode).toBe(Mode.NONE)
    await db.update(dialogs).set({ notificationSettings: null }).where(eq(dialogs.id, parentDialog!.id))
    inherited = await resolve()
    expect(inherited.has(recipient.id)).toBe(false)
    expect(resolveEffectiveNotificationMode({ globalMode: GlobalMode.Mentions, dialogNotificationSettings: inherited.get(recipient.id) })).toBe(GlobalMode.Mentions)
    expect((await getInheritedDialogNotificationSettings(root.id, [other.id])).get(other.id)?.mode).toBe(Mode.ALL)
    expect((await getInheritedDialogNotificationSettings(nestedId, [])).size).toBe(0)
  })
})
