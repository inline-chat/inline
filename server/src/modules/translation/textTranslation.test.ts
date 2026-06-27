import { afterEach, describe, expect, mock, test } from "bun:test"

const parseCompletion = mock()
const getCachedUserName = mock(getUserNameFromDb)

mock.module("@in/server/libs/openAI", () => ({
  openaiClient: {
    chat: {
      completions: {
        parse: parseCompletion,
      },
    },
  },
}))

mock.module("@in/server/modules/cache/userNames", () => ({
  getCachedUserName,
  UserNamesCache: {
    getCachedUserName,
    getDisplayName,
  },
}))

mock.module("@in/server/modules/notifications/eval", () => ({
  relativeTimeFromNow: () => "just now",
}))

describe("translateTexts", () => {
  afterEach(() => {
    parseCompletion.mockReset()
    getCachedUserName.mockReset()
    getCachedUserName.mockImplementation(getUserNameFromDb)
  })

  test("places context messages inside an explicit non-translatable boundary block", async () => {
    getCachedUserName.mockResolvedValue({
      id: 7,
      firstName: "Alice",
      lastName: null,
      username: null,
      email: null,
      phone: null,
      timeZone: null,
      cacheDate: Date.now(),
    })
    parseCompletion.mockResolvedValue({
      choices: [
        {
          finish_reason: "stop",
          message: {
            content: '{"translations":[{"messageId":12,"translation":"bonjour"}]}',
            parsed: {
              translations: [{ messageId: 12, translation: "bonjour" }],
            },
          },
        },
      ],
    })

    const { translateTexts } = await import("./textTranslation")
    await translateTexts({
      messages: [
        {
          messageId: 12,
          fromId: 7,
          date: new Date("2026-03-20T00:00:00Z"),
          text: "hello",
        } as any,
      ],
      contextMessages: [
        {
          fromId: 7,
          text: "this is context only",
        } as any,
      ],
      language: "fr",
      chat: {
        id: 99,
        title: "Product",
        type: "thread",
      } as any,
      actorId: 7,
    })

    const request = parseCompletion.mock.calls[0]?.[0]
    const systemPrompt = request?.messages?.[0]?.content

    expect(systemPrompt).toContain("BEGIN_CONTEXT_MESSAGES")
    expect(systemPrompt).toContain("END_CONTEXT_MESSAGES")
    expect(systemPrompt).toContain("Never translate, quote, summarize, or include text from BEGIN_CONTEXT_MESSAGES")
  })

  test("throws when the model returns missing or unexpected message ids", async () => {
    parseCompletion.mockResolvedValue({
      choices: [
        {
          finish_reason: "stop",
          message: {
            content:
              '{"translations":[{"messageId":12,"translation":"bonjour"},{"messageId":77,"translation":"unexpected"}]}',
            parsed: {
              translations: [
                { messageId: 12, translation: "bonjour" },
                { messageId: 77, translation: "unexpected" },
              ],
            },
          },
        },
      ],
    })

    const { translateTexts } = await import("./textTranslation")

    await expect(
      translateTexts({
        messages: [
          {
            messageId: 12,
            fromId: 7,
            date: new Date("2026-03-20T00:00:00Z"),
            text: "hello",
          } as any,
          {
            messageId: 13,
            fromId: 8,
            date: new Date("2026-03-20T00:00:00Z"),
            text: "world",
          } as any,
        ],
        language: "fr",
        chat: {
          id: 99,
          title: "Product",
          type: "thread",
        } as any,
        actorId: 7,
      }),
    ).rejects.toThrow("Invalid translation output")
  })
})

async function getUserNameFromDb(userId: number) {
  const [{ db }, { users }, { eq }] = await Promise.all([
    import("@in/server/db"),
    import("@in/server/db/schema"),
    import("drizzle-orm"),
  ])

  const user = await db
    .select()
    .from(users)
    .where(eq(users.id, userId))
    .then(([user]) => user)

  if (!user) return undefined

  return {
    id: userId,
    firstName: user.firstName,
    lastName: user.lastName,
    username: user.username,
    email: user.emailVerified ? user.email : null,
    phone: user.phoneVerified ? user.phoneNumber : null,
    timeZone: user.timeZone,
    cacheDate: Date.now(),
  }
}

function getDisplayName(userName: Awaited<ReturnType<typeof getUserNameFromDb>>): string | null {
  if (!userName) return null
  return userName.firstName ?? userName.lastName ?? userName.username ?? userName.email ?? userName.phone ?? null
}
