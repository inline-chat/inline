import { Cause, Context, Effect, Layer } from "effect"
import type { RequestId } from "../helpers/requestId"
import type { DiagnosticText } from "../schema/diagnostics"

export interface UnexpectedErrorContext {
  /** Stable operation name, never a raw URL or user-controlled value. */
  readonly operation: string
  readonly requestId?: RequestId | undefined
  readonly connectionId?: DiagnosticText | undefined
  readonly clientIp?: DiagnosticText | undefined
  readonly userAgent?: DiagnosticText | undefined
  readonly origin?: DiagnosticText | undefined
  readonly host?: DiagnosticText | undefined
}

export interface UnexpectedErrorReport<E> {
  /** Private structured cause. It must never be serialized into a public response. */
  readonly cause: Cause.Cause<E>
  readonly context: UnexpectedErrorContext
}

export interface ErrorReporterShape {
  /**
   * Records an unexpected failure at an explicit boundary.
   *
   * Implementations must absorb their own reporting failures so observability
   * cannot replace the failure being reported.
   */
  readonly report: <E>(report: UnexpectedErrorReport<E>) => Effect.Effect<void>
}

export class ErrorReporter extends Context.Service<ErrorReporter, ErrorReporterShape>()(
  "@inline/server/core/ErrorReporter",
) {
  static readonly Noop: Layer.Layer<ErrorReporter> = Layer.succeed(ErrorReporter)({
    report: () => Effect.void,
  })
}

export const reportUnexpectedError = <E>(
  report: UnexpectedErrorReport<E>,
): Effect.Effect<void, never, ErrorReporter> => ErrorReporter.use((reporter) => reporter.report(report))
