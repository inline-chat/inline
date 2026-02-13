import { describe, expect, test } from "bun:test"
import { DialogNotificationSettings_Mode } from "@inline-chat/protocol/core"
import { UserSettingsNotificationsMode } from "@in/server/db/models/userSettings/types"
import { decideNotification } from "@in/server/modules/notifications/decision"
import { resolveEffectiveNotificationMode } from "@in/server/modules/notifications/dialogNotificationSettings"

describe("notification decision", () => {
  test("global none + per-chat all notifies", () => {
    const mode = resolveEffectiveNotificationMode({
      globalMode: UserSettingsNotificationsMode.None,
      dialogNotificationSettings: {
        mode: DialogNotificationSettings_Mode.ALL,
      },
    })

    const decision = decideNotification({
      mode,
      isUrgentNudge: false,
      isNudge: false,
      isDM: false,
      isReplyToUser: false,
      isExplicitlyMentioned: false,
      aiRequiresNotification: false,
    })

    expect(decision.shouldNotify).toBe(true)
  })

  test("global all + per-chat none suppresses", () => {
    const mode = resolveEffectiveNotificationMode({
      globalMode: UserSettingsNotificationsMode.All,
      dialogNotificationSettings: {
        mode: DialogNotificationSettings_Mode.NONE,
      },
    })

    const decision = decideNotification({
      mode,
      isUrgentNudge: false,
      isNudge: false,
      isDM: true,
      isReplyToUser: false,
      isExplicitlyMentioned: false,
      aiRequiresNotification: false,
    })

    expect(decision.shouldNotify).toBe(false)
  })

  test("global only mentions + per-chat mentions uses mentions DM behavior", () => {
    const mode = resolveEffectiveNotificationMode({
      globalMode: UserSettingsNotificationsMode.OnlyMentions,
      dialogNotificationSettings: {
        mode: DialogNotificationSettings_Mode.MENTIONS,
      },
    })

    const decision = decideNotification({
      mode,
      isUrgentNudge: false,
      isNudge: false,
      isDM: true,
      isReplyToUser: false,
      isExplicitlyMentioned: false,
      aiRequiresNotification: false,
    })

    expect(decision.shouldNotify).toBe(true)
    expect(decision.needsExplicitMacNotification).toBe(true)
  })

  test("global only mentions without per-chat setting suppresses unmentioned DM", () => {
    const decision = decideNotification({
      mode: UserSettingsNotificationsMode.OnlyMentions,
      isUrgentNudge: false,
      isNudge: false,
      isDM: true,
      isReplyToUser: false,
      isExplicitlyMentioned: false,
      aiRequiresNotification: false,
    })

    expect(decision.shouldNotify).toBe(false)
  })

  test("mentions mode notifies explicit mentions in threads", () => {
    const decision = decideNotification({
      mode: UserSettingsNotificationsMode.Mentions,
      isUrgentNudge: false,
      isNudge: false,
      isDM: false,
      isReplyToUser: false,
      isExplicitlyMentioned: true,
      aiRequiresNotification: false,
    })

    expect(decision.shouldNotify).toBe(true)
    expect(decision.needsExplicitMacNotification).toBe(true)
  })

  test("urgent nudge bypasses none mode", () => {
    const decision = decideNotification({
      mode: UserSettingsNotificationsMode.None,
      isUrgentNudge: true,
      isNudge: true,
      isDM: false,
      isReplyToUser: false,
      isExplicitlyMentioned: false,
      aiRequiresNotification: false,
    })

    expect(decision.shouldNotify).toBe(true)
  })

  test("all mode sends standard notification without explicit mac reason", () => {
    const decision = decideNotification({
      mode: UserSettingsNotificationsMode.All,
      isUrgentNudge: false,
      isNudge: false,
      isDM: false,
      isReplyToUser: false,
      isExplicitlyMentioned: false,
      aiRequiresNotification: false,
    })

    expect(decision.shouldNotify).toBe(true)
    expect(decision.needsExplicitMacNotification).toBe(false)
  })

  test("important only requires both mention context and AI/nudge signal", () => {
    const noSignal = decideNotification({
      mode: UserSettingsNotificationsMode.ImportantOnly,
      isUrgentNudge: false,
      isNudge: false,
      isDM: false,
      isReplyToUser: true,
      isExplicitlyMentioned: false,
      aiRequiresNotification: false,
    })

    expect(noSignal.shouldNotify).toBe(false)

    const withSignal = decideNotification({
      mode: UserSettingsNotificationsMode.ImportantOnly,
      isUrgentNudge: false,
      isNudge: false,
      isDM: false,
      isReplyToUser: true,
      isExplicitlyMentioned: false,
      aiRequiresNotification: true,
    })

    expect(withSignal.shouldNotify).toBe(true)
    expect(withSignal.needsExplicitMacNotification).toBe(true)
  })

  test("unspecified per-chat mode falls back to global mode", () => {
    const mode = resolveEffectiveNotificationMode({
      globalMode: UserSettingsNotificationsMode.Mentions,
      dialogNotificationSettings: {
        mode: DialogNotificationSettings_Mode.UNSPECIFIED,
      },
    })

    expect(mode).toBe(UserSettingsNotificationsMode.Mentions)
  })
})
