import { describe, expect, it } from "vitest"
import {
  chatNotificationGroup,
  decideMessageNotification,
  isFreshMessage,
  isViewingConversation,
  messageNotificationTag,
  resolveNotificationMode,
  type ChatNotificationMode,
  type GlobalNotificationMode,
  type MessageNotificationFacts,
} from "./notification-policy"

const NOW = 1_700_000_000_000
const nowSeconds = NOW / 1000

/** A fresh, unread, incoming group message in a chat on the default mode, global mode `all`. */
const base: MessageNotificationFacts = {
  outgoing: false,
  newlyInserted: true,
  unread: true,
  dateSeconds: nowSeconds - 5,
  nowMs: NOW,
  viewingConversation: false,
  chatMode: "global",
  globalMode: "all",
  directMessage: false,
  mentionsMe: false,
}

const decide = (overrides: Partial<MessageNotificationFacts>) => decideMessageNotification({ ...base, ...overrides })

describe("rule 12: gates before the mode", () => {
  const cases: [string, Partial<MessageNotificationFacts>, string][] = [
    ["outgoing", { outgoing: true }, "outgoing"],
    ["edit or re-delivery", { newlyInserted: false }, "not-new"],
    ["already read", { unread: false }, "read"],
    ["countsAsUnread false", { countsAsUnread: false }, "does-not-count-as-unread"],
    ["call transcript", { callTranscript: true }, "call-transcript"],
    ["silent send", { silentSend: true }, "silent-send"],
    ["121 s old", { dateSeconds: nowSeconds - 121 }, "stale"],
    ["no date", { dateSeconds: 0 }, "stale"],
    ["NaN date", { dateSeconds: Number.NaN }, "stale"],
    ["viewing the conversation", { viewingConversation: true }, "viewing"],
  ]
  it.each(cases)("%s does not notify", (_name, overrides, reason) => {
    expect(decide(overrides)).toEqual({ notify: false, reason })
  })

  it("exactly 120 s old still notifies; a future date counts as fresh", () => {
    expect(decide({ dateSeconds: nowSeconds - 120 }).notify).toBe(true)
    expect(decide({ dateSeconds: nowSeconds + 30 }).notify).toBe(true)
  })

  it("countsAsUnread absent means it counts", () => {
    expect(decide({}).notify).toBe(true)
  })
})

describe("rule 12: urgent nudges", () => {
  it("notify while viewing, in mode none, and always with sound", () => {
    expect(
      decide({ urgentNudge: true, nudge: true, viewingConversation: true, chatMode: "none", soundEnabled: false }),
    ).toEqual({ notify: true, urgent: true, silent: false })
  })

  it("still respect the delivery gates", () => {
    expect(decide({ urgentNudge: true, dateSeconds: nowSeconds - 600 })).toEqual({ notify: false, reason: "stale" })
    expect(decide({ urgentNudge: true, unread: false })).toEqual({ notify: false, reason: "read" })
    expect(decide({ urgentNudge: true, silentSend: true })).toEqual({ notify: false, reason: "silent-send" })
    expect(decide({ urgentNudge: true, outgoing: true })).toEqual({ notify: false, reason: "outgoing" })
  })
})

describe("rule 12: mode table", () => {
  type Kind = "plain" | "dm" | "mention" | "reply" | "nudge"
  const kinds: Record<Kind, Partial<MessageNotificationFacts>> = {
    plain: {},
    dm: { directMessage: true },
    mention: { mentionsMe: true },
    reply: { repliesToMe: true },
    nudge: { nudge: true },
  }
  // Expected per effective mode, from MacNotifications.shouldScheduleMessageNotification.
  const table: Record<"all" | "mentions" | "onlyMentions" | "none", Record<Kind, boolean>> = {
    all: { plain: true, dm: true, mention: true, reply: true, nudge: true },
    mentions: { plain: false, dm: true, mention: true, reply: true, nudge: true },
    onlyMentions: { plain: false, dm: false, mention: true, reply: false, nudge: true },
    none: { plain: false, dm: false, mention: false, reply: false, nudge: false },
  }
  const viaGlobal: [GlobalNotificationMode, keyof typeof table][] = [
    ["all", "all"],
    ["mentions", "mentions"],
    ["importantOnly", "mentions"],
    ["onlyMentions", "onlyMentions"],
    ["none", "none"],
  ]
  const viaChat: [ChatNotificationMode, keyof typeof table][] = [
    ["all", "all"],
    ["mentions", "mentions"],
    ["none", "none"],
  ]

  for (const [globalMode, effective] of viaGlobal) {
    for (const kind of Object.keys(kinds) as Kind[]) {
      it(`chat default, global ${globalMode}, ${kind} → ${table[effective][kind]}`, () => {
        const decision = decide({ ...kinds[kind], chatMode: "global", globalMode })
        expect(decision.notify).toBe(table[effective][kind])
        if (!decision.notify) expect(decision.reason).toBe("mode")
      })
    }
  }

  for (const [chatMode, effective] of viaChat) {
    for (const globalMode of ["all", "none", "onlyMentions"] as const) {
      for (const kind of Object.keys(kinds) as Kind[]) {
        it(`chat ${chatMode} overrides global ${globalMode}, ${kind} → ${table[effective][kind]}`, () => {
          expect(decide({ ...kinds[kind], chatMode, globalMode }).notify).toBe(table[effective][kind])
        })
      }
    }
  }
})

describe("sound", () => {
  it("is silent only when the user turned sound off", () => {
    expect(decide({})).toEqual({ notify: true, urgent: false, silent: false })
    expect(decide({ soundEnabled: false })).toEqual({ notify: true, urgent: false, silent: true })
  })
})

describe("helpers", () => {
  it("resolves modes as the Mac compat layer does", () => {
    expect(resolveNotificationMode("global", "importantOnly")).toBe("mentions")
    expect(resolveNotificationMode("global", "onlyMentions")).toBe("onlyMentions")
    expect(resolveNotificationMode("mentions", "all")).toBe("mentions")
  })

  it("fresh means positive and at most two minutes old", () => {
    expect(isFreshMessage(nowSeconds - 119, NOW)).toBe(true)
    expect(isFreshMessage(nowSeconds - 121, NOW)).toBe(false)
    expect(isFreshMessage(-1, NOW)).toBe(false)
  })

  it("viewing needs visible, focused and the same chat", () => {
    const viewing = { visible: true, focused: true, openChatId: "7", chatId: "7" }
    expect(isViewingConversation(viewing)).toBe(true)
    expect(isViewingConversation({ ...viewing, visible: false })).toBe(false)
    expect(isViewingConversation({ ...viewing, focused: false })).toBe(false)
    expect(isViewingConversation({ ...viewing, openChatId: "8" })).toBe(false)
    expect(isViewingConversation({ ...viewing, openChatId: null })).toBe(false)
  })

  it("uses the Mac identifiers", () => {
    expect(messageNotificationTag("12", "345")).toBe("chat_12_message_345")
    expect(chatNotificationGroup("12")).toBe("chat_12")
  })
})
