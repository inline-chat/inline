import { realtime } from "@in/server/realtime"
import { newWebsocket, wsOpen } from "@in/server/realtime/test/utils"
import { delay } from "@in/server/utils/helpers/time"
import { describe, it, expect } from "bun:test"
import Elysia from "elysia"

describe("realtime api", () => {
  it("should be able to connect", async () => {
    const app = new Elysia()
    app.use(realtime)
    app.listen(0)

    const ws = newWebsocket(app.server!)
    await wsOpen(ws)
  })

  it("should not accept string messages", async () => {
    const app = new Elysia()
    app.use(realtime)
    app.listen(0)

    const ws = newWebsocket(app.server!)
    await wsOpen(ws)

    ws.send("hello")
    await delay(5)
    expect(ws.readyState).toBe(WebSocket.CLOSED)
  })
})
