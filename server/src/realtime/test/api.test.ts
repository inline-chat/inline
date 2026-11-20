import { useLiveRealtimeHost } from "@in/server/__tests__/liveRealtimeHost"
import { newWebsocket, wsOpen } from "@in/server/realtime/test/utils"
import { describe, it } from "bun:test"

describe("realtime api", () => {
  const host = useLiveRealtimeHost()

  it("should be able to connect", async () => {
    const ws = newWebsocket(host.server)
    await wsOpen(ws)
  })

  // it("should not accept string messages", async () => {
  //   const ws = newWebsocket(host.server)
  //   await wsOpen(ws)

  //   ws.send("hello")
  //   await delay(5)
  //   expect(ws.readyState).toBe(WebSocket.CLOSED)
  // })
})
