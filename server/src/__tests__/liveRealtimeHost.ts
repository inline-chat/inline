import type { Server } from "bun"
import { afterAll, beforeAll } from "bun:test"
import { Effect, Exit, Layer } from "effect"
import { makeRuntimeBridge } from "@in/server/core/effect/runtimeBridge"
import type { ErrorReporter } from "@in/server/core/errors/errorReporter"
import { ErrorReporterLive } from "@in/server/core/errors/errorReporterLive"
import { makeCombinedWebsocket, type CoreWebSocketData } from "@in/server/core/http/combinedWebsocket"
import { makeCoreRealtimeTransport, type CoreRealtimeTransport } from "@in/server/core/http/realtimeHost"
import { RealtimeSessions } from "@in/server/realtime/host.effect"
import { makeLegacyRealtimeSessions } from "@in/server/realtime/legacyHostAdapter.effect"

export interface LiveRealtimeHost {
  /** The listening server; available from the file's `beforeAll` on. */
  readonly server: Server<CoreWebSocketData>
}

/**
 * The production v2 realtime host: `makeCoreRealtimeTransport` with the
 * sessions `productionRuntime.ts` provides, behind the listener options,
 * upgrade step and registry binding `productionHost.ts` uses. It serves no HTTP
 * routes, Inline Protocol V3 or background processes; other requests get 404.
 * Listens on 127.0.0.1 with an ephemeral port before the suite and drains its
 * sockets after it.
 */
export const useLiveRealtimeHost = (): LiveRealtimeHost => {
  const bridge = makeRuntimeBridge(
    Layer.merge(Layer.succeed(RealtimeSessions)(makeLegacyRealtimeSessions()), ErrorReporterLive),
  )
  let transport: CoreRealtimeTransport | undefined
  let server: Server<CoreWebSocketData> | undefined

  beforeAll(async () => {
    const contextExit = await bridge.runPromiseExit(Effect.context<ErrorReporter | RealtimeSessions>())
    if (Exit.isFailure(contextExit)) {
      throw new Error("The live realtime host failed to build.", { cause: contextExit.cause })
    }
    const realtime = makeCoreRealtimeTransport(contextExit.value)
    transport = realtime
    server = Bun.serve<CoreWebSocketData>({
      hostname: "127.0.0.1",
      port: 0,
      fetch: (request, bunServer) => {
        const upgrade = realtime.tryUpgrade(request, bunServer as never)
        if (upgrade instanceof Response) return upgrade
        if (upgrade) return undefined
        return new Response("Not found", { status: 404 })
      },
      websocket: makeCombinedWebsocket(realtime.websocket),
    })
    const { connectionManager } = await import("@in/server/ws/connections")
    connectionManager.setServer(server)
  })

  afterAll(async () => {
    await transport?.shutdown()
    await server?.stop(true)
    await bridge.dispose()
  })

  return {
    get server() {
      if (server === undefined) throw new Error("The live realtime host is not listening yet.")
      return server
    },
  }
}
