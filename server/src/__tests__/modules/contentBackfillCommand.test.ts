import { afterEach, describe, expect, it } from "bun:test"
import { sql } from "drizzle-orm"
import { db } from "@in/server/db"
import { chats, messages } from "@in/server/db/schema"
import { CONTENT_PREFIX } from "@in/server/modules/encryption/contentEncryption"
import { REQUIRED_PRODUCTION_VARIABLES } from "@in/server/envRequirements"
import { setupTestLifecycle, testUtils } from "../setup"

const originalMode = process.env["CONTENT_ENCRYPTION_WRITES"]
describe("packaged content migration command", () => {
  setupTestLifecycle()
  afterEach(() => {
    if (originalMode === undefined) Reflect.deleteProperty(process.env, "CONTENT_ENCRYPTION_WRITES")
    else process.env["CONTENT_ENCRYPTION_WRITES"] = originalMode
  })
  it("refuses unsafe targets, missing acknowledgements, disabled writers and a competing runner", async () => {
    process.env["CONTENT_ENCRYPTION_WRITES"] = "false"
    const sentinel = "private-command-guard-sentinel"
    await testUtils.createChat(null, sentinel)
    const [target] = await db.execute<{ name: string }>(sql`select current_database() as name`)
    if (!target?.name.startsWith("test_db_")) throw new Error("Expected isolated test database")
    const run = async (args: string[], environment: Record<string, string> = {}) => {
      const child = Bun.spawn([process.execPath, "scripts/encrypt-content.ts", ...args], {
        cwd: new URL("../../../", import.meta.url).pathname,
        env: { ...process.env, NODE_ENV: "test", SENTRY_DSN: "",
          TEST_DATABASE_URL: process.env["DATABASE_URL"], ...environment }, stdout: "pipe", stderr: "pipe",
      })
      const [exit, stdout, stderr] = await Promise.all([child.exited,
        new Response(child.stdout).text(), new Response(child.stderr).text()])
      expect(exit).toBe(1)
      expect(stdout + stderr).not.toContain(sentinel)
      expect(stdout + stderr).not.toContain(process.env["ENCRYPTION_KEY"]!)
      return stderr
    }
    expect(await run(["--database", "wrong_target"])).toContain('"phase":"configuration"')
    expect(await run(["--database", target.name, "--apply"])).toContain('"phase":"arguments"')
    expect(await run(["--database", target.name, "--apply", "--backup-verified", "--readers-ready"]))
      .toContain("Enable encrypted writers")
    expect(await run(["--database", target.name, "--apply", "--backup-verified", "--readers-ready"], {
      CONTENT_ENCRYPTION_WRITES: "true", INLINE_PROTOCOL_REPLAY_KEY_RING_JSON: "",
    })).toContain("Replay encryption rollout is required")
    await db.transaction(async (tx) => {
      await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended('inline-content-backfill-v1', 0))`)
      expect(await run(["--database", target.name])).toContain("Another content backfill is running")
    })
    expect((await db.execute<{ title: string }>(sql`select title from chats`))[0]!.title).toBe(sentinel)
  })

  it("runs verify, interrupted apply and safe reruns without printing authored data", async () => {
    process.env["CONTENT_ENCRYPTION_WRITES"] = "false"
    const user = await testUtils.createUser()
    const secret = "private-backfill-command-sentinel"
    const chat = (await testUtils.createChat(null, secret))!
    for (let i = 0; i < 9; i++) await testUtils.createChat(null, secret)
    await db.insert(messages).values({ chatId: chat.id, fromId: user.id, messageId: 1, text: secret })
    const [target] = await db.execute<{ name: string }>(sql`select current_database() as name`)
    if (!target?.name.startsWith("test_db_")) throw new Error("Expected isolated test database")
    const artifact = process.env["CONTENT_BACKFILL_TEST_ARTIFACT"] === "true"
    const artifactEnvironment = artifact ? Object.fromEntries(REQUIRED_PRODUCTION_VARIABLES
      .filter((name) => name !== "DATABASE_URL" && name !== "ENCRYPTION_KEY")
      .map((name) => [name, name === "R2_ENDPOINT" ? "https://example.invalid" : "synthetic"])) : {}
    const run = async (apply: boolean, interrupt = false) => {
      const subprocess = Bun.spawn([process.execPath, artifact ? "dist/encrypt-content.js" : "scripts/encrypt-content.ts", "--database", target.name,
        ...(apply ? ["--apply", "--backup-verified", "--readers-ready"] : []), ...(interrupt ? ["--batch-size", "1"] : [])], {
        cwd: new URL("../../../", import.meta.url).pathname,
        env: { ...process.env, ...artifactEnvironment, SENTRY_DSN: artifact ? "https://public@example.invalid/1" : "", NODE_ENV: "test", DATABASE_URL: process.env["DATABASE_URL"],
          TEST_DATABASE_URL: process.env["DATABASE_URL"], CONTENT_ENCRYPTION_WRITES: "true",
          INLINE_PROTOCOL_ENCRYPT_REPLAY_RESULTS: "true",
          INLINE_PROTOCOL_REPLAY_KEY_RING_JSON: JSON.stringify({ activeId: "test", keys: { test: Buffer.alloc(32, 7).toString("base64") } }),
        }, stdout: "pipe", stderr: "pipe",
      })
      const readOutput = async () => {
        let output = ""
        let signaled = false
        const decoder = new TextDecoder()
        for await (const chunk of subprocess.stdout) {
          output += decoder.decode(chunk, { stream: true })
          if (interrupt && !signaled && output.includes('"table":"chats","scanned":1,"changed":1')) {
            signaled = true
            subprocess.kill("SIGTERM")
          }
        }
        return output + decoder.decode()
      }
      const [exit, stdout, stderr] = await Promise.all([subprocess.exited,
        readOutput(), new Response(subprocess.stderr).text()])
      expect(stdout + stderr).not.toContain(secret)
      const safeFailure = stderr.split("\n").find((line) => line.startsWith('{"status":"stopped"'))
      expect(exit, safeFailure ?? "Child command failed before its diagnostic handler").toBe(interrupt ? 1 : 0)
      if (interrupt) expect(stderr).toContain("Backfill interrupted; rerun to resume")
      else expect(stdout).toContain(apply ? '"status":"complete"' : '"status":"verified"')
    }
    await run(false)
    expect((await db.select().from(chats))[0]!.title).toBe(secret)
    expect((await db.select().from(messages))[0]!.text).toBe(secret)
    await run(true, true)
    const partial = await db.execute<{ title: string }>(sql`select title from chats`)
    expect(partial.some((row) => row.title === secret)).toBe(true)
    expect(partial.some((row) => row.title.startsWith(CONTENT_PREFIX))).toBe(true)
    await run(true)
    await run(true)
    expect((await db.select().from(chats))[0]!.title).toBe(secret)
    expect((await db.select().from(messages))[0]!.text).toBeNull()
    expect((await db.execute<{ title: string }>(sql`select title from chats`))[0]!.title.startsWith(CONTENT_PREFIX)).toBe(true)
  })
})
