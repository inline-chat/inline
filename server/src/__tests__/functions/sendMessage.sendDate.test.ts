import { describe, expect, spyOn, test } from "bun:test"
import { desc, eq } from "drizzle-orm"
import { setupTestLifecycle, testUtils } from "../setup"
import { db } from "@in/server/db"
import { messages } from "@in/server/db/schema"
import {
  CLIENT_SEND_DATE_MAX_FUTURE_MS,
  CLIENT_SEND_DATE_MAX_PAST_MS,
  resolveMessageDate,
} from "@in/server/modules/message/clientSendDate"
import { sendMessage } from "@in/server/realtime/handlers/messages.sendMessage"
import { Log } from "@in/server/utils/log"

const YEAR_2000 = 946_684_800n
const YEAR_2099 = 4_070_908_800n

/** Sends through the realtime handler and returns the stored date with the receipt window around it. */
const sendWithClientDate = async (temporarySendDate: bigint | undefined) => {
  const user = await testUtils.createUser(`send-date-${crypto.randomUUID()}@example.com`)
  const chat = await testUtils.createPrivateChat(user, user)
  if (!chat) throw new Error("Failed to create self chat")

  const before = Date.now()
  await sendMessage(
    {
      peerId: { type: { oneofKind: "chat", chat: { chatId: BigInt(chat.id) } } },
      message: "dated",
      randomId: BigInt(Math.floor(Math.random() * 1_000_000_000)),
      temporarySendDate,
    },
    {
      userId: user.id,
      sessionId: 1,
      connectionId: "send-date-test",
      sendRaw: () => {},
      sendRpcReply: () => {},
    },
  )
  const after = Date.now()

  const [stored] = await db
    .select({ date: messages.date })
    .from(messages)
    .where(eq(messages.chatId, chat.id))
    .orderBy(desc(messages.messageId))
    .limit(1)
  if (!stored?.date) throw new Error("Message was not stored")
  return { stored: stored.date.getTime(), before, after, userId: user.id, chatId: chat.id }
}

describe("sendMessage client send date", () => {
  setupTestLifecycle()

  test.each([
    ["year 2000", YEAR_2000],
    ["year 2099", YEAR_2099],
    ["int64 max", 9_223_372_036_854_775_807n],
    ["absent", undefined],
  ])("dates a message with a %s client send date at server receipt", async (_label, temporarySendDate) => {
    const { stored, before, after } = await sendWithClientDate(temporarySendDate)
    expect(stored).toBeGreaterThanOrEqual(before)
    expect(stored).toBeLessThanOrEqual(after)
  })

  test.each([
    ["behind", -90],
    ["ahead of", 90],
  ])("keeps a client send date 90 seconds %s receipt", async (_label, offsetSeconds) => {
    const clientDate = BigInt(Math.floor(Date.now() / 1000) + offsetSeconds)
    const { stored } = await sendWithClientDate(clientDate)
    expect(stored).toBe(Number(clientDate) * 1000)
  })

  test("logs each replaced send date with the sender, chat, and drift", async () => {
    const info = spyOn(Log.prototype, "info")
    try {
      const { userId, chatId } = await sendWithClientDate(YEAR_2000)
      const lines = info.mock.calls.filter(([message]) => message === "replaced client send date outside the drift window")
      expect(lines).toHaveLength(1)
      const fields = lines[0]?.[1] as { userId: number; chatId: number; driftSeconds: number } | undefined
      expect(fields).toMatchObject({ userId, chatId })
      expect(fields?.driftSeconds).toBeLessThan(-800_000_000)
    } finally {
      info.mockRestore()
    }
  })
})

describe("resolveMessageDate", () => {
  const now = Date.UTC(2026, 9, 20, 12, 0, 0)

  test("keeps send dates within the window either side of receipt", () => {
    expect(CLIENT_SEND_DATE_MAX_PAST_MS).toBe(120_000)
    expect(CLIENT_SEND_DATE_MAX_FUTURE_MS).toBe(120_000)
    expect(resolveMessageDate(now / 1000 - 120, now)).toEqual({ date: new Date(now - 120_000), replaced: false })
    expect(resolveMessageDate(now / 1000 + 120, now)).toEqual({ date: new Date(now + 120_000), replaced: false })
    expect(resolveMessageDate(undefined, now)).toEqual({ date: new Date(now), replaced: false })
  })

  test("replaces anything else with receipt time", () => {
    for (const sendDate of [now / 1000 - 121, now / 1000 + 121, 0, -1, Number.NaN, Number.POSITIVE_INFINITY, 1e300]) {
      expect(resolveMessageDate(sendDate, now)).toEqual({ date: new Date(now), replaced: true })
    }
  })
})
