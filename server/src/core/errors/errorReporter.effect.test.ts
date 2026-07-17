import { describe, expect, it } from "@effect/vitest"
import { Cause, Effect } from "effect"
import { ErrorReporter, reportUnexpectedError } from "./errorReporter"
import {
  ErrorReportJournal,
  RecordingErrorReporter,
} from "../testing/errorReporter"
import { RequestId } from "../helpers/requestId"
import {
  MAX_DIAGNOSTIC_TEXT_LENGTH,
  toDiagnosticText,
} from "../schema/diagnostics"

describe("ErrorReporter", () => {
  it.layer(RecordingErrorReporter)("recording boundary", (it) => {
    it.effect("keeps the structured private cause and safe context", () =>
      Effect.gen(function* () {
        const cause = Cause.fail({ _tag: "DatabaseUnavailable" as const, retryable: true })

        yield* reportUnexpectedError({
          cause,
          context: {
            operation: "waitlist.subscribe",
            requestId: RequestId.make("request-42"),
          },
        })

        const journal = yield* ErrorReportJournal
        const entries = yield* journal.entries

        expect(entries).toHaveLength(1)
        expect(entries[0]?.cause).toBe(cause)
        expect(entries[0]?.context).toEqual({
          operation: "waitlist.subscribe",
          requestId: "request-42",
        })
      }),
    )
  })

  it.layer(RecordingErrorReporter)("isolated recording boundary", (it) => {
    it.effect("starts with a fresh journal in a sibling layer block", () =>
      Effect.gen(function* () {
        const journal = yield* ErrorReportJournal
        expect(yield* journal.entries).toEqual([])
      }),
    )
  })

  it.effect("provides an explicit no-op reporter when observation is intentionally absent", () =>
    ErrorReporter.use((reporter) =>
      reporter.report({
        cause: Cause.fail("private"),
        context: { operation: "test.noop" },
      }),
    ).pipe(Effect.provide(ErrorReporter.Noop)),
  )

  it("bounds request-derived diagnostic text before it reaches a report", () => {
    const diagnostic = toDiagnosticText(
      `  ${"x".repeat(
        MAX_DIAGNOSTIC_TEXT_LENGTH + 40,
      )}  `,
    )

    expect(diagnostic).toHaveLength(
      MAX_DIAGNOSTIC_TEXT_LENGTH,
    )
    expect(diagnostic?.endsWith("...")).toBe(
      true,
    )
    expect(toDiagnosticText("   ")).toBeUndefined()
  })
})
