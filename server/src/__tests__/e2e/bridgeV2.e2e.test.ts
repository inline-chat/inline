import { afterAll, beforeAll, describe, expect, mock, test } from "bun:test"
import path from "node:path"
import Elysia from "elysia"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"
import { db } from "@in/server/db"
import { users } from "@in/server/db/schema"
import { eq } from "drizzle-orm"

// The bridge v2 end-to-end runs: this side creates an owner, their bot and
// their DM, serves realtime, and runs the Rust side
// (`cli/src/bridge/v2/e2e.rs`), which drives the real v2 runtime and the real
// harness (`codex app-server`, or `claude`) against a local fake model.
// Discovered only with INLINE_E2E=1 (see scripts/test-discovery.ts); it needs
// Codex and Claude Code installed and builds the CLI tests.
setupTestLifecycle()

// The server makes no model calls of its own here: untitled threads (`/new`)
// keep their default titles instead of asking OpenAI for one.
mock.module("@in/server/libs/openAI", () => ({ openaiClient: undefined }))

describe("bridge v2 end to end", () => {
  let app: any

  beforeAll(async () => {
    const { realtime } = await import("@in/server/realtime")
    app = new Elysia().use(realtime)
    app.listen({ port: 0, hostname: "127.0.0.1" })
  })

  afterAll(() => {
    app?.server?.stop?.()
  })

  async function runRustSide(testName: string) {
    const suffix = crypto.randomUUID()
    const owner = await testUtils.createUser(`bridge-v2-owner-${suffix}@example.test`)
    const bot = await testUtils.createUser(`bridge-v2-bot-${suffix}@example.test`)
    if (!owner || !bot) throw new Error("users missing")
    await db.update(users).set({ bot: true, botCreatorId: owner.id }).where(eq(users.id, bot.id))
    const { chat: dm } = await testUtils.createPrivateChatWithOptionalDialog({
      userA: owner,
      userB: bot,
      createDialogForUserA: true,
      createDialogForUserB: true,
    })
    const { token: ownerToken } = await testUtils.createSessionForUser(owner.id, { clientType: "cli" })
    const { token: botToken } = await testUtils.createSessionForUser(bot.id, { clientType: "api" })

    const origin = `127.0.0.1:${app.server.port}`
    const repo = path.resolve(import.meta.dir, "../../../..")
    const cargo = Bun.spawn(
      ["cargo", "test", "-j", "2", "-p", "inline-cli", `bridge::v2::e2e::${testName}`,
        "--", "--ignored", "--exact", "--nocapture"],
      {
        cwd: repo,
        env: {
          ...process.env,
          CARGO_TARGET_DIR: process.env["INLINE_BRIDGE_V2_E2E_TARGET"] ?? path.join(repo, "target"),
          INLINE_V2_E2E_REALTIME_URL: `ws://${origin}/realtime`,
          INLINE_V2_E2E_API_URL: `http://${origin}`,
          INLINE_V2_E2E_BOT_TOKEN: botToken,
          INLINE_V2_E2E_OWNER_TOKEN: ownerToken,
          INLINE_V2_E2E_BOT_USER_ID: String(bot.id),
          INLINE_V2_E2E_OWNER_USER_ID: String(owner.id),
          INLINE_V2_E2E_DM_CHAT_ID: String(dm.id),
        },
        stdout: "inherit",
        stderr: "inherit",
      },
    )
    expect(await cargo.exited).toBe(0)
  }

  test("Codex: a DM answers, uses Inline tools, asks for approval and releases; a group work moves into a subthread", async () => {
    await runRustSide("codex_round_trip_through_inline")
  }, 30 * 60_000)

  test("Claude Code: a DM answers, uses Inline tools, asks for approval and releases", async () => {
    await runRustSide("claude_round_trip_through_inline")
  }, 30 * 60_000)
})
