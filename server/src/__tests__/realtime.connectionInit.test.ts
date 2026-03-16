import { beforeEach, describe, expect, mock, test } from "bun:test"
import type { HandlerContext } from "@in/server/realtime/types"

const logWarn = mock()
const logError = mock()
const getUserIdFromToken = mock()
const authenticateConnection = mock()
const where = mock(async () => undefined)
const set = mock(() => ({ where }))
const update = mock(() => ({ set }))

mock.module("@in/server/utils/log", () => ({
  Log: class {
    warn = logWarn
    error = logError
    info() {}
    debug() {}
    trace() {}
  },
  LogLevel: {},
}))

mock.module("@in/server/controllers/plugins", () => ({
  getUserIdFromToken,
}))

mock.module("@in/server/ws/connections", () => ({
  connectionManager: {
    authenticateConnection,
  },
}))

mock.module("@in/server/db", () => ({
  db: {
    update,
  },
}))

mock.module("@in/server/db/schema", () => ({
  sessions: {
    id: Symbol("id"),
    userId: Symbol("userId"),
  },
}))

mock.module("drizzle-orm", () => ({
  and: (...values: unknown[]) => values,
  eq: (left: unknown, right: unknown) => [left, right],
}))

mock.module("@in/server/utils/validate", () => ({
  validateUpToFourSegementSemver: (value: string) => value === "1.2.3",
}))

const handlerContext: HandlerContext = {
  userId: 1,
  sessionId: 2,
  connectionId: "test-connection",
  sendRaw() {},
  sendRpcReply() {},
}

describe("handleConnectionInit", () => {
  beforeEach(() => {
    logWarn.mockReset()
    logError.mockReset()
    getUserIdFromToken.mockReset()
    authenticateConnection.mockReset()
    where.mockReset()
    set.mockReset()
    update.mockReset()

    where.mockResolvedValue(undefined)
    set.mockImplementation(() => ({ where }))
    update.mockImplementation(() => ({ set }))
    getUserIdFromToken.mockResolvedValue({ userId: 1, sessionId: 2 })
  })

  test("ignores invalid client version without warning and falls back to build number", async () => {
    const { handleConnectionInit } = await import("@in/server/realtime/handlers/_connectionInit")

    await handleConnectionInit(
      {
        token: "token",
        clientVersion: "unknown",
        buildNumber: 123,
        layer: 2,
      },
      handlerContext,
    )

    expect(logWarn).not.toHaveBeenCalled()
    expect(set).toHaveBeenCalledWith({ clientVersion: "123" })
    expect(authenticateConnection).toHaveBeenCalledWith("test-connection", 1, 2, 2)
  })
})
