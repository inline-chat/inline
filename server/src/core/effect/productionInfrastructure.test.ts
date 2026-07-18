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
  ErrorReportJournal,
  RecordingErrorReporter,
} from "../testing/errorReporter"
import {
  makeProductionInfrastructureLayer,
} from "./productionInfrastructure"

describe("production infrastructure Layer", () => {
  it.layer(RecordingErrorReporter)(
    "owns ordered compatibility finalizers",
    (it) => {
      it.effect(
        "releases APN, database, then telemetry and reports without aborting",
        () =>
          Effect.gen(function* () {
            const releases:
              Array<string> = []
            yield* Effect.scoped(
              Layer.build(
                makeProductionInfrastructureLayer({
                  shutdownPushProvider:
                    () => {
                      releases.push("apn")
                    },
                  closeDatabase: () => {
                    releases.push(
                      "database",
                    )
                    throw new Error(
                      "database close failed",
                    )
                  },
                  flushTelemetry:
                    () => {
                      releases.push(
                        "telemetry",
                      )
                    },
                }),
              ),
            )

            expect(releases).toEqual([
              "apn",
              "database",
              "telemetry",
            ])
            const journal =
              yield* ErrorReportJournal
            const reports =
              yield* journal.entries
            expect(reports).toHaveLength(1)
            expect(
              reports[0]?.context
                .operation,
            ).toBe(
              "infrastructure.database.stop",
            )
          }),
      )
    },
  )
})
