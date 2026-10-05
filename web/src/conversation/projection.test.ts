import { DbObjectKind, messageKey, type Message } from "@inline/client/core"
import { chatId, messageId, userId } from "@inline/ids"
import { describe, expect, it } from "vitest"
import { dayKey, projectConversation, titleForChat } from "./projection"

const message = (id: number, date: number, overrides: Partial<Message> = {}): Message => ({
  kind: DbObjectKind.Message,
  id: messageKey(chatId(10), messageId(id)),
  messageId: messageId(id),
  chatId: chatId(10),
  fromId: userId(7),
  date,
  ...overrides,
})

describe("conversation projection", () => {
  it("groups adjacent same-sender messages within five minutes", () => {
    const rows = projectConversation([message(1, 100), message(2, 400), message(3, 701)])
    const messages = rows.filter((row) => row.kind === "message")
    expect(messages.map((row) => [row.groupedWithPrevious, row.groupedWithNext])).toEqual([
      [false, true],
      [true, false],
      [false, false],
    ])
  })

  it("breaks sender groups across dates, service messages, replies, and different senders", () => {
    const midnight = new Date(2026, 9, 5).getTime() / 1000
    const rows = projectConversation([
      message(1, midnight - 1),
      message(2, midnight),
      message(3, midnight + 1, { fromId: userId(8) }),
      message(4, midnight + 2, { replyToMsgId: messageId(1) }),
      message(5, midnight + 3, { serviceMessage: { event: { oneofKind: undefined } } }),
      message(6, midnight + 4),
    ])
    expect(rows.filter((row) => row.kind === "day")).toHaveLength(2)
    expect(
      rows.filter((row) => row.kind === "message").every((row) => !row.groupedWithPrevious),
    ).toBe(true)
    expect(dayKey(midnight - 1)).not.toBe(dayKey(midnight))
  })

  it("uses exact chat-scoped semantic message identity", () => {
    const source = message(9000, 1, { randomId: 15n })
    expect(projectConversation([source]).at(-1)?.key).toBe(source.id)
  })

  it("names DMs from the exact peer and retains thread-number fallback", () => {
    expect(
      titleForChat({ kind: DbObjectKind.Chat, id: chatId(1), peerUserId: userId(7) }, [
        { kind: DbObjectKind.User, id: userId(7), firstName: "Dena", lastName: "Smith" },
      ]),
    ).toBe("Dena Smith")
    expect(titleForChat({ kind: DbObjectKind.Chat, id: chatId(1), number: 12 }, [])).toBe(
      "Thread 12",
    )
  })
})
