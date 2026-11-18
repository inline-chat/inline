import type { MessageRow, UserRow } from "@inline/core-protocol"
import type { ChatID, MessageID, UserID } from "@inline/ids"
import type { TimeFormatter } from "@inline/chat-ui"
import { describe, expect, it } from "vitest"
import { createMessageTimes, presentReply, presentSender } from "./presentation"

const chatId = "7" as ChatID
const message = (id: string, text: string, extra: Partial<MessageRow> = {}): MessageRow => ({
  kind: "message",
  id,
  chatId,
  messageId: id.split(":")[1] as MessageID,
  fromId: "1" as UserID,
  out: false,
  date: 1_700_000_000,
  text,
  state: "sent",
  ...extra,
})

describe("presentation helpers", () => {
  const user: UserRow = { kind: "user", id: "5" as UserID, firstName: "Ada", lastName: "Lovelace", username: "ada" }

  it("presents a sender once per user row", () => {
    const sender = presentSender(user)
    expect(sender).toMatchObject({ userId: "5", name: "Ada", fullName: "Ada Lovelace", seed: "Ada Lovelace" })
    expect(sender.color).toMatch(/^rgb\(/)
    expect(presentSender(user)).toBe(sender)
  })

  it("presents a reply line, with a stable fallback while the original is missing", () => {
    const missing = presentReply("9" as MessageID, undefined, undefined)
    expect(missing).toMatchObject({ missing: true, text: "Original message" })
    expect(presentReply("9" as MessageID, undefined, undefined)).toBe(missing)

    const sender = presentSender(user)
    const replied = message("7:9", "A long\nmultiline   original")
    const line = presentReply("9" as MessageID, replied, sender)
    expect(line).toMatchObject({ missing: false, senderName: "Ada", text: "A long multiline original" })
    expect(presentReply("9" as MessageID, replied, sender)).toBe(line)
  })

  it("formats each minute once", () => {
    let calls = 0
    const formatter: TimeFormatter = {
      time: (seconds) => {
        calls += 1
        return `t${seconds}`
      },
      tooltip: (seconds) => `tip${seconds}`,
      dayLabel: () => ({ kind: "today", text: "Today" }),
      dayNumber: () => 0,
    }
    const times = createMessageTimes(formatter)
    expect(times.time(120)).toBe("t120")
    expect(times.time(150)).toBe("t120")
    expect(times.time(181)).toBe("t180")
    expect(calls).toBe(2)
    expect(times.tooltip(61)).toBe("tip60")
  })
})
