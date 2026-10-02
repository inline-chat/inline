import { describe, expect, test } from "bun:test"
import { createHmac } from "node:crypto"
import { parseSelector, eventCatalog } from "./catalog"
import { canonicalSelector, decodeCursor, encodeCursor, occurrenceId, signature, signingKey, subscriptionId } from "./crypto"
import { McpEventsError } from "./types"

const secret = `whsec_${Buffer.alloc(32, 0x42).toString("base64")}`
const binding = { grantId: "grant-a", name: "message.created", selector: { chatId: "12", excludeSelf: true }, bucket: { kind: "chat" as const, entityId: 12 } }

describe("MCP event wire security", () => {
  test("signs exact Standard Webhooks bytes using the decoded whsec key", () => {
    const body = '{"unicode":"hello ☀️","line":"one\\ntwo"}'
    const expected = createHmac("sha256", Buffer.alloc(32, 0x42)).update(`evt_1.123456.${body}`).digest("base64")
    expect(signature(secret, "evt_1", 123456, body)).toBe(`v1,${expected}`)
    expect(signature(secret, "evt_1", 123456, `${body} `)).not.toBe(`v1,${expected}`)
  })
  test("rejects malformed, noncanonical and undersized signing keys", () => {
    for (const value of ["", "whsec_%%%", `whsec_${Buffer.alloc(23).toString("base64")}`, `whsec_${Buffer.alloc(65).toString("base64")}`, "whsec_AAAAA"]) expect(() => signingKey(value)).toThrow(McpEventsError)
    expect(signingKey(secret)).toHaveLength(32)
  })
  test("cursor decrypts only for its exact grant, name, selector and bucket", () => {
    const cursor = encodeCursor(binding, 101)
    expect(cursor).not.toContain("grant-a")
    expect(decodeCursor(cursor, binding)).toBe(101)
    for (const other of [{ ...binding, grantId: "grant-b" }, { ...binding, name: "message.updated" }, { ...binding, selector: { chatId: "12" } }, { ...binding, bucket: { kind: "chat" as const, entityId: 13 } }]) expect(() => decodeCursor(cursor, other)).toThrow(McpEventsError)
    const last = cursor.at(-4) === "A" ? "B" : "A"
    expect(() => decodeCursor(`${cursor.slice(0, -4)}${last}${cursor.slice(-3)}`, binding)).toThrow(McpEventsError)
  })
  test("canonical identities normalize false excludeSelf and object key order", () => {
    expect(canonicalSelector({ excludeSelf: true, chatId: "12" })).toBe(canonicalSelector({ chatId: "12", excludeSelf: true }))
    expect(subscriptionId("g", "message.created", { chatId: "12", excludeSelf: false }, "https://receiver.test/")).toBe(subscriptionId("g", "message.created", { chatId: "12" }, "https://receiver.test/"))
    expect(occurrenceId(binding, 4)).toBe(occurrenceId(binding, 4))
    expect(occurrenceId(binding, 5)).not.toBe(occurrenceId(binding, 4))
  })
  test("catalog requires one bounded resource and excludes unsupported live events", () => {
    for (const args of [{}, { chatId: "12", spaceId: "3" }, { chatId: "2147483648" }, { chatId: "012" }, { chatId: "12", unrelated: true }]) expect(() => parseSelector("message.created", args)).toThrow(McpEventsError)
    expect(() => parseSelector("chat.updated", { chatId: "12", excludeSelf: true })).toThrow(McpEventsError)
    expect(parseSelector("message.created", { chatId: "12", excludeSelf: false })).toEqual({ chatId: "12" })
    expect(() => parseSelector("reaction.created", { chatId: "12" })).toThrow(McpEventsError)
    expect(eventCatalog()).toHaveLength(18)
    expect(eventCatalog().every((entry) => entry.delivery[0] === "webhook")).toBe(true)
  })
})
