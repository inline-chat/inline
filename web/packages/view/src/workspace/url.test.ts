import { chatId, messageId, spaceId, userId } from "@inline/ids"
import { describe, expect, test } from "vitest"
import { chatInfoTabs, settingsPages, spacePages, type Destination } from "./destination"
import { decodeAppPath, encodeDestination, parseLink, toAppUrl, toDeepLink, toPublicLink } from "./url"

const token = `iv1_${"A".repeat(20)}-_${"b9".repeat(10)}c`

/** One of every destination shape, including every optional field set and unset. */
const everyDestination: Destination[] = [
  { kind: "empty" },
  { kind: "chat", chatId: chatId("123") },
  { kind: "chat", chatId: chatId("9223372036854775807") },
  { kind: "message", chatId: chatId("12"), messageId: messageId("3456") },
  { kind: "thread", parentChatId: chatId("12"), threadId: chatId("98") },
  { kind: "chatInfo", chatId: chatId("12") },
  ...chatInfoTabs.map((tab): Destination => ({ kind: "chatInfo", chatId: chatId("12"), tab })),
  { kind: "user", userId: userId("77") },
  { kind: "allChats" },
  { kind: "archived" },
  { kind: "newThread" },
  { kind: "newThread", spaceId: spaceId("5") },
  { kind: "createSpace" },
  ...spacePages.map((page): Destination => ({ kind: "space", spaceId: spaceId("5"), page })),
  { kind: "settings" },
  ...settingsPages.map((page): Destination => ({ kind: "settings", page })),
  { kind: "search" },
  { kind: "search", query: "hello world & more/?#%" },
  { kind: "search", query: "سلام" },
  { kind: "signIn" },
  { kind: "signIn", next: { kind: "chat", chatId: chatId("1") } },
  { kind: "signIn", next: { kind: "search", query: "a b" } },
  { kind: "signIn", next: { kind: "message", chatId: chatId("1"), messageId: messageId("2") } },
  { kind: "joinSpace", handle: "TownHall" },
  { kind: "joinSpace", handle: "a-b_c9" },
  { kind: "invite", token },
]

describe("app path round trip", () => {
  test.each(everyDestination.map((d) => [encodeDestination(d), d] as const))("%s", (path, destination) => {
    expect(path.startsWith("/")).toBe(true)
    const decoded = decodeAppPath(path)
    expect(decoded).toEqual({ ok: true, destination })
    // Stable: encoding the decoded value gives the same path.
    expect(encodeDestination(decoded.destination)).toBe(path)
  })

  test("covers every destination kind", () => {
    const kinds = new Set(everyDestination.map((d) => d.kind))
    const all: Destination["kind"][] = [
      "empty",
      "chat",
      "message",
      "thread",
      "chatInfo",
      "user",
      "allChats",
      "archived",
      "newThread",
      "createSpace",
      "space",
      "settings",
      "search",
      "signIn",
      "joinSpace",
      "invite",
    ]
    expect([...kinds].sort()).toEqual([...all].sort())
  })

  test("paths are short and match the public inline.chat forms", () => {
    expect(encodeDestination({ kind: "chat", chatId: chatId("1") })).toBe("/c/1")
    expect(encodeDestination({ kind: "message", chatId: chatId("1"), messageId: messageId("2") })).toBe("/c/1/m/2")
    expect(encodeDestination({ kind: "joinSpace", handle: "TownHall" })).toBe("/s/TownHall")
    expect(encodeDestination({ kind: "invite", token })).toBe(`/invite/${token}`)
    expect(encodeDestination({ kind: "user", userId: userId("4") })).toBe("/u/4")
  })
})

describe("app path aliases", () => {
  test.each([
    ["/c/1/", { kind: "chat", chatId: "1" }],
    ["/c/1#top", { kind: "chat", chatId: "1" }],
    ["/C/1", { kind: "chat", chatId: "1" }],
    ["/c/1/message/2", { kind: "message", chatId: "1", messageId: "2" }],
    ["/s/@TownHall", { kind: "joinSpace", handle: "TownHall" }],
    ["/settings/nope", { kind: "settings" }],
    ["/c/1/info/nope", { kind: "chatInfo", chatId: "1" }],
    ["/search?q=", { kind: "search" }],
    ["/sign-in?next=/sign-in", { kind: "signIn" }],
    ["/sign-in?next=https://evil.example/c/1", { kind: "signIn" }],
    ["/sign-in?next=//evil.example/c/1", { kind: "signIn" }],
    ["/sign-in?next=/nope", { kind: "signIn" }],
  ])("%s", (path, destination) => {
    expect(decodeAppPath(path)).toEqual({ ok: true, destination })
  })
})

describe("malformed and unknown app paths", () => {
  test.each([
    ["", "malformed"],
    ["c/1", "malformed"],
    ["//evil.example/c/1", "malformed"],
    ["/c/%E0%A4%A", "malformed"],
    ["/c/abc", "malformed"],
    ["/c/0", "malformed"],
    ["/c/-5", "malformed"],
    ["/c/007", "malformed"],
    ["/c/9223372036854775808", "malformed"],
    ["/c/1.5", "malformed"],
    ["/c/1/m/x", "malformed"],
    ["/c/1/t/0", "malformed"],
    ["/u/x", "malformed"],
    ["/space/x/members", "malformed"],
    ["/s/a", "malformed"],
    ["/s/-abc", "malformed"],
    ["/invite/iv1_short", "malformed"],
    ["/nope", "unknown"],
    ["/c/1/m", "unknown"],
    ["/c/1/m/2/3", "unknown"],
    ["/c/1/elsewhere", "unknown"],
    ["/u/1/2", "unknown"],
    ["/chats/extra", "unknown"],
    ["/space/5/nope", "unknown"],
    ["/space/5", "unknown"],
    ["/s/a/b", "unknown"],
  ])("%j is %s and falls back to empty", (path, reason) => {
    expect(decodeAppPath(path)).toEqual({ ok: false, destination: { kind: "empty" }, reason })
  })

  test("never throws on hostile input", () => {
    const inputs: unknown[] = [undefined, null, 42, {}, "%", "/%", "/c/%", "/?%=%", "/search?q=%E0%A4%A", "\u0000", "/".repeat(5000)]
    for (const input of inputs) {
      expect(() => decodeAppPath(input as string)).not.toThrow()
      expect(() => parseLink(input as string)).not.toThrow()
    }
  })
})

describe("links from elsewhere", () => {
  test.each([
    // Apple deep links (InlineDeepLink.swift).
    ["inline://chat/12", { kind: "chat", chatId: "12" }],
    ["in://chat/12", { kind: "chat", chatId: "12" }],
    ["INLINE://CHAT/12", { kind: "chat", chatId: "12" }],
    ["inline://thread/12", { kind: "chat", chatId: "12" }],
    ["inline://chat/12/message/34", { kind: "message", chatId: "12", messageId: "34" }],
    ["inline://thread/12/message/34", { kind: "message", chatId: "12", messageId: "34" }],
    ["inline://chat?id=12", { kind: "chat", chatId: "12" }],
    ["inline://chat?chatId=12&messageId=34", { kind: "message", chatId: "12", messageId: "34" }],
    ["inline://chat?CHAT_ID=12", { kind: "chat", chatId: "12" }],
    ["inline://user/7", { kind: "user", userId: "7" }],
    ["inline://user?user_id=7", { kind: "user", userId: "7" }],
    ["inline://join/public/TownHall", { kind: "joinSpace", handle: "TownHall" }],
    [`inline://join/invite/${token}`, { kind: "invite", token }],
    // Public web links the server produces.
    ["https://inline.chat/c/12", { kind: "chat", chatId: "12" }],
    ["https://inline.chat/s/TownHall", { kind: "joinSpace", handle: "TownHall" }],
    ["https://inline.chat/s/@TownHall", { kind: "joinSpace", handle: "TownHall" }],
    [`https://inline.chat/invite/${token}`, { kind: "invite", token }],
    // App URLs and paths.
    ["https://app.inline.chat/c/12/m/34", { kind: "message", chatId: "12", messageId: "34" }],
    ["https://app.inline.chat/search?q=hi", { kind: "search", query: "hi" }],
    ["/settings/appearance", { kind: "settings", page: "appearance" }],
  ])("%s", (href, destination) => {
    expect(parseLink(href)).toEqual(destination)
  })

  test.each([
    "inline://chat/0",
    "inline://chat/12/extra",
    "inline://chat/12/message/0",
    "inline://user/1/2",
    "inline://join/public/x",
    "inline://join/other/abc",
    "inline://nowhere/1",
    "inline-dev://chat/1",
    "https://inline.chat/u/1",
    "https://inline.chat/c/1/m/2",
    "https://inline.chat:8443/c/1",
    "http://inline.chat/c/1",
    "https://evil.example/c/1",
    "https://inline.chat.evil.example/c/1",
    "javascript:alert(1)",
    "mailto:a@b.c",
    "not a url",
    "//inline.chat/c/1",
  ])("%s is not ours", (href) => {
    expect(parseLink(href)).toBeUndefined()
  })

  test("development schemes and app origins are configurable", () => {
    expect(parseLink("inline-dev://chat/1", { extraSchemes: ["inline-dev"] })).toEqual({ kind: "chat", chatId: "1" })
    expect(parseLink("http://localhost:8001/c/1", { appOrigins: ["http://localhost:8001"] })).toEqual({
      kind: "chat",
      chatId: "1",
    })
  })

  test("generated links parse back to the same destination", () => {
    for (const destination of everyDestination) {
      const deep = toDeepLink(destination)
      if (deep) {
        const expected =
          destination.kind === "thread" ? { kind: "chat", chatId: destination.threadId } : destination
        expect(parseLink(deep)).toEqual(expected)
      }
      const publicLink = toPublicLink(destination)
      if (publicLink) {
        const expected =
          destination.kind === "thread" ? { kind: "chat", chatId: destination.threadId } : destination
        expect(parseLink(publicLink)).toEqual(expected)
      }
      expect(parseLink(toAppUrl(destination))).toEqual(destination)
    }
  })

  test("only chats, spaces and invites have public links, as on the Apple clients", () => {
    expect(toPublicLink({ kind: "user", userId: userId("1") })).toBeUndefined()
    expect(toPublicLink({ kind: "message", chatId: chatId("1"), messageId: messageId("2") })).toBeUndefined()
    expect(toDeepLink({ kind: "settings" })).toBeUndefined()
  })
})
