import { afterEach, describe, expect, it, mock, spyOn } from "bun:test"
import type { DbUser } from "@in/server/db/schema"
import { UsersModel } from "@in/server/db/models/users"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { encodeMessageVia, knownViaApp, resolveMessageVia } from "@in/server/modules/message/via"

const OWNER_ID = 10
const human = async () => false
const bot = (overrides: Partial<DbUser>) =>
  ({ id: 77, bot: true, botCreatorId: OWNER_ID, deleted: null, firstName: "Atlas", lastName: null, username: "atlas_bot", ...overrides }) as DbUser

afterEach(() => {
  mock.restore()
})

describe("knownViaApp", () => {
  it("keeps known agents and normalizes case", () => {
    expect(knownViaApp("codex")).toBe("codex")
    expect(knownViaApp(" Claude-Code ")).toBe("claude-code")
  })

  it("turns unknown names into the generic agent", () => {
    expect(knownViaApp("Inline Support")).toBe("agent")
    expect(knownViaApp("constructor")).toBe("agent")
  })
})

describe("resolveMessageVia", () => {
  it("leaves a message plain without via", async () => {
    expect(await resolveMessageVia({ via: undefined, currentUserId: OWNER_ID, senderIsBot: human })).toEqual({
      viaApp: null,
      viaBotUserId: null,
      viaName: null,
    })
  })

  it("stores a known app and maps unknown ones to the generic agent", async () => {
    const known = await resolveMessageVia({
      via: { source: { oneofKind: "app", app: "opencode" } },
      currentUserId: OWNER_ID,
      senderIsBot: human,
    })
    expect(known).toEqual({ viaApp: "opencode", viaBotUserId: null, viaName: null })

    const unknown = await resolveMessageVia({
      via: { source: { oneofKind: "app", app: "Sara's bot" } },
      currentUserId: OWNER_ID,
      senderIsBot: human,
    })
    expect(unknown).toEqual({ viaApp: "agent", viaBotUserId: null, viaName: null })
  })

  it("ignores via from bots, which always send as themselves", async () => {
    const result = await resolveMessageVia({
      via: { source: { oneofKind: "app", app: "codex" } },
      currentUserId: OWNER_ID,
      senderIsBot: async () => true,
    })
    expect(result).toEqual({ viaApp: null, viaBotUserId: null, viaName: null })
  })

  it("accepts a bot the sender owns", async () => {
    spyOn(UsersModel, "getUserById").mockResolvedValue(bot({}))
    const result = await resolveMessageVia({
      via: { source: { oneofKind: "botUserId", botUserId: 77n } },
      currentUserId: OWNER_ID,
      senderIsBot: human,
    })
    expect(result).toEqual({ viaApp: null, viaBotUserId: 77, viaName: "Atlas" })
  })

  it("falls back to the bot's username and keeps names short", async () => {
    spyOn(UsersModel, "getUserById").mockResolvedValue(bot({ firstName: null, username: "metrics_bot" }))
    const byUsername = await resolveMessageVia({
      via: { source: { oneofKind: "botUserId", botUserId: 77n } },
      currentUserId: OWNER_ID,
      senderIsBot: human,
    })
    expect(byUsername.viaName).toBe("metrics_bot")

    spyOn(UsersModel, "getUserById").mockResolvedValue(bot({ firstName: "x".repeat(100) }))
    const long = await resolveMessageVia({
      via: { source: { oneofKind: "botUserId", botUserId: 77n } },
      currentUserId: OWNER_ID,
      senderIsBot: human,
    })
    expect(long.viaName).toHaveLength(64)
  })

  it.each([
    ["someone else's bot", bot({ botCreatorId: 99 })],
    ["a person", bot({ bot: false })],
    ["a deleted bot", bot({ deleted: true })],
    ["a missing user", undefined],
  ])("rejects %s", async (_label, user) => {
    spyOn(UsersModel, "getUserById").mockResolvedValue(user)
    const pending = resolveMessageVia({
      via: { source: { oneofKind: "botUserId", botUserId: 77n } },
      currentUserId: OWNER_ID,
      senderIsBot: human,
    })
    await expect(pending).rejects.toBeInstanceOf(RealtimeRpcError)
  })
})

describe("encodeMessageVia", () => {
  it("is absent for plain messages", () => {
    expect(encodeMessageVia({ viaApp: null, viaBotUserId: null, viaName: null })).toBeUndefined()
    expect(encodeMessageVia({})).toBeUndefined()
  })

  it("names known apps", () => {
    expect(encodeMessageVia({ viaApp: "codex", viaBotUserId: null, viaName: null })).toEqual({
      source: { oneofKind: "app", app: "codex" },
      name: "Codex",
    })
    expect(encodeMessageVia({ viaApp: "agent", viaBotUserId: null, viaName: null })?.name).toBe("an AI agent")
  })

  it("encodes a bot signer by id with its name at send time", () => {
    expect(encodeMessageVia({ viaApp: null, viaBotUserId: 77, viaName: "Atlas" })).toEqual({
      source: { oneofKind: "botUserId", botUserId: 77n },
      name: "Atlas",
    })
    expect(encodeMessageVia({ viaApp: null, viaBotUserId: 77, viaName: null })).toEqual({
      source: { oneofKind: "botUserId", botUserId: 77n },
    })
  })
})
