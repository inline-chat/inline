import { Context, Effect, Layer, Ref } from "effect"
import {
  ErrorReporter,
  type ErrorReporterShape,
  type UnexpectedErrorReport,
} from "../errors/errorReporter"

export interface ErrorReportJournalShape {
  readonly entries: Effect.Effect<ReadonlyArray<UnexpectedErrorReport<unknown>>>
  readonly clear: Effect.Effect<void>
  readonly append: <E>(report: UnexpectedErrorReport<E>) => Effect.Effect<void>
}

export class ErrorReportJournal extends Context.Service<ErrorReportJournal, ErrorReportJournalShape>()(
  "@inline/server/core/testing/ErrorReportJournal",
) {}

const JournalLive = Layer.effect(
  ErrorReportJournal,
  Effect.gen(function* () {
    const entries = yield* Ref.make<ReadonlyArray<UnexpectedErrorReport<unknown>>>([])

    return {
      entries: Ref.get(entries),
      clear: Ref.set(entries, []),
      append: <E>(report: UnexpectedErrorReport<E>) =>
        Ref.update(entries, (current) => [...current, report]),
    }
  }),
)

const ReporterLive = Layer.effect(
  ErrorReporter,
  ErrorReportJournal.use(
    (journal) =>
      Effect.succeed<ErrorReporterShape>({
        report: (report) => journal.append(report),
      }),
  ),
)

/**
 * Fresh, in-memory reporter and journal for an `it.layer` block.
 *
 * Reusing this Layer value is safe: `@effect/vitest` rebuilds and disposes it
 * for each independent `it.layer` block.
 */
export const RecordingErrorReporter = Layer.merge(
  JournalLive,
  ReporterLive.pipe(Layer.provide(JournalLive)),
)
