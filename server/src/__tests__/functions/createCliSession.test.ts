import { beforeEach, describe, expect, test } from "bun:test"
import { eq } from "drizzle-orm"
import { db, schema } from "@in/server/db"
import { createCliSession } from "@in/server/functions/user.createCliSession"
import type { FunctionContext } from "@in/server/functions/_types"
import { getUserIdFromToken } from "@in/server/controllers/plugins"
import { setupTestLifecycle, testUtils } from "../setup"

describe("createCliSession", () => {
  setupTestLifecycle()

  let userId: number
  let context: FunctionContext

  beforeEach(async () => {
    const user = await testUtils.createUser("cli-session@example.com")
    const source = await testUtils.createSessionForUser(user.id, {
      clientType: "macos",
      deviceName: "Source Mac",
    })
    userId = user.id
    context = { currentUserId: user.id, currentSessionId: source.session.id }
  })

  test("creates an independently authenticated CLI session", async () => {
    const result = await createCliSession(
      {
        deviceId: "cli_0123456789abcdef0123456789abcdef",
        deviceName: "Mo's MacBook Pro",
        clientVersion: "0.6.2",
        osVersion: "15.5",
      },
      context,
    )

    const authenticated = await getUserIdFromToken(result.token)
    expect(result.userId).toBe(BigInt(userId))
    expect(authenticated.userId).toBe(userId)
    expect(authenticated.sessionId).toBe(Number(result.sessionId))

    const [session] = await db
      .select()
      .from(schema.sessions)
      .where(eq(schema.sessions.id, Number(result.sessionId)))
      .limit(1)
    expect(session?.clientType).toBe("cli")
    expect(session?.deviceId).toBe("cli_0123456789abcdef0123456789abcdef")
    expect(session?.clientVersion).toBe("0.6.2")
    expect(session?.osVersion).toBe("15.5")
  })

  test("rotates an existing CLI session for the same device id", async () => {
    const input = {
      deviceId: "cli_0123456789abcdef0123456789abcdef",
      clientVersion: "0.6.2",
    }
    const first = await createCliSession(input, context)
    const second = await createCliSession(input, context)

    expect(second.token).not.toBe(first.token)
    await expect(getUserIdFromToken(first.token)).rejects.toThrow()
    await expect(getUserIdFromToken(second.token)).resolves.toMatchObject({ userId })
  })

  test("rejects sessions that are not active macOS sessions for the current user", async () => {
    const web = await testUtils.createSessionForUser(userId, { clientType: "web" })
    await expect(
      createCliSession(
        { deviceId: "cli_0123456789abcdef0123456789abcdef", clientVersion: "0.6.2" },
        { currentUserId: userId, currentSessionId: web.session.id },
      ),
    ).rejects.toThrow("Bad request")

    const otherUser = await testUtils.createUser("other-cli-session@example.com")
    await expect(
      createCliSession(
        { deviceId: "cli_0123456789abcdef0123456789abcdef", clientVersion: "0.6.2" },
        { currentUserId: otherUser.id, currentSessionId: context.currentSessionId },
      ),
    ).rejects.toThrow("Bad request")

    await db
      .update(schema.sessions)
      .set({ revoked: new Date() })
      .where(eq(schema.sessions.id, context.currentSessionId))
    await expect(
      createCliSession(
        { deviceId: "cli_0123456789abcdef0123456789abcdef", clientVersion: "0.6.2" },
        context,
      ),
    ).rejects.toThrow("Bad request")
  })

  test("rejects malformed CLI metadata", async () => {
    await expect(
      createCliSession({ deviceId: "../../wrong", clientVersion: "not-semver" }, context),
    ).rejects.toThrow("Bad request")

    await expect(
      createCliSession(
        {
          deviceId: "cli_0123456789abcdef0123456789abcdef",
          deviceName: "bad\ndevice",
          clientVersion: "0.6.2",
        },
        context,
      ),
    ).rejects.toThrow("Bad request")
  })
})
