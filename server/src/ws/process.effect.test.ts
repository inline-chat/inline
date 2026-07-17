import {
  describe,
  expect,
  it,
} from "@effect/vitest"
import {
  Effect,
  Layer,
} from "effect"
import {
  ErrorReporter,
} from "../core/errors/errorReporter"
import {
  RealtimeStateProcess,
  makeRealtimeStateProcessLayer,
} from "./process.effect"

describe("realtime state process Layer", () => {
  it.effect(
    "shuts down connections before presence",
    () =>
      Effect.gen(function* () {
        const events: Array<string> = []
        const owners = {
          connections: {
            shutdown: () => {
              events.push("connections")
            },
          },
          presence: {
            shutdown: () => {
              events.push("presence")
            },
          },
        }
        const layer =
          makeRealtimeStateProcessLayer({
            start: () => {
              events.push("start")
              return owners
            },
            stop: async (owned) => {
              await owned.connections.shutdown()
              await owned.presence.shutdown()
            },
          }).pipe(
            Layer.provide(ErrorReporter.Noop),
          )

        yield* RealtimeStateProcess.use(
          (process) =>
            Effect.sync(() => {
              expect(process.owners).toBe(
                owners,
              )
            }),
        ).pipe(Effect.provide(layer))

        expect(events).toEqual([
          "start",
          "connections",
          "presence",
        ])
      }),
  )
})
