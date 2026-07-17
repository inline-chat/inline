import {
  describe,
  expect,
  it,
} from "@effect/vitest"
import {
  Cause,
  Effect,
  Fiber,
} from "effect"
import {
  ErrorReporter,
} from "../../core/errors/errorReporter"
import {
  ErrorReportJournal,
  RecordingErrorReporter,
} from "../../core/testing/errorReporter"
import {
  ProcessServiceStartFailure,
  acquireOwnedProcess,
} from "./ownedProcess.effect"

describe("owned process lifetime", () => {
  it.effect(
    "keeps startup failure typed",
    () =>
      Effect.gen(function* () {
        const failure = yield* Effect.flip(
          Effect.scoped(
            acquireOwnedProcess({
              name: "database-health-monitor",
              start: () => {
                throw new Error("private startup cause")
              },
              stop: () => {},
            }),
          ).pipe(
            Effect.provide(
              ErrorReporter.Noop,
            ),
          ),
        )

        expect(failure).toBeInstanceOf(
          ProcessServiceStartFailure,
        )
        expect(failure.service).toBe(
          "database-health-monitor",
        )
      }),
  )

  it.effect(
    "releases the process when its owner is interrupted",
    () =>
      Effect.gen(function* () {
        const events: Array<string> = []
        let signalStarted = () => {}
        const started = new Promise<void>(
          (resolve) => {
            signalStarted = resolve
          },
        )
        const owner = yield* Effect.scoped(
          Effect.gen(function* () {
            yield* acquireOwnedProcess({
              name: "realtime-state",
              start: () => {
                events.push("start")
                signalStarted()
                return { running: true }
              },
              stop: () => {
                events.push("stop")
              },
            })
            yield* Effect.never
          }),
        ).pipe(
          Effect.provide(
            ErrorReporter.Noop,
          ),
          Effect.forkChild,
        )

        yield* Effect.promise(() => started)
        yield* Fiber.interrupt(owner)

        expect(events).toEqual([
          "start",
          "stop",
        ])
      }),
  )

  it.layer(RecordingErrorReporter)(
    "release reporting",
    (it) => {
      it.effect(
        "reports and absorbs a finalizer failure exactly once",
        () =>
          Effect.gen(function* () {
            yield* Effect.scoped(
              acquireOwnedProcess({
                name: "grid-provider-effects",
                start: () => ({ started: true }),
                stop: () => {
                  throw new Error(
                    "private shutdown cause",
                  )
                },
              }),
            )

            const journal =
              yield* ErrorReportJournal
            const reports = yield* journal.entries

            expect(reports).toHaveLength(1)
            expect(
              reports[0]?.context.operation,
            ).toBe(
              "process.grid-provider-effects.stop",
            )
            expect(
              Cause.pretty(
                reports[0]?.cause ??
                  Cause.empty,
              ),
            ).toContain(
              "ProcessServiceStopFailure",
            )
          }),
      )
    },
  )
})
