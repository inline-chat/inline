import {
  Context,
  Effect,
  ErrorReporter as EffectErrorReporter,
  Layer,
  Option,
} from "effect"
import { Log } from "@in/server/utils/log"
import {
  ErrorReporter,
  type ErrorReporterShape,
} from "./errorReporter"
import {
  HttpRequestContext,
  type HttpRequestContextShape,
} from "../http/requestContext"

const log = new Log("server.effect")

const safeLogError = (
  message: string,
  error: unknown,
  metadata: Record<string, unknown>,
): void => {
  try {
    log.error(message, error, metadata)
  } catch {
    // Observability must never replace the failure it is reporting.
  }
}

const requestMetadata = (
  context: Context.Context<never>,
): Record<string, unknown> => {
  const requestContext = Context.getOption(
    context,
    HttpRequestContext,
  )

  return Option.match(requestContext, {
    onNone: () => ({}),
    onSome: (request: HttpRequestContextShape) => ({
      method: request.method,
      path: request.path,
      requestId: request.requestId,
    }),
  })
}

const inlineReporter: ErrorReporterShape = {
  report: ({ cause, context }) =>
    Effect.sync(() => {
      safeLogError("Unexpected Effect failure", cause, {
        ...context,
      })
    }),
}

const effectReporter = EffectErrorReporter.make(
  ({ error, severity, attributes, fiber }) => {
    safeLogError("Effect boundary failure", error, {
      ...attributes,
      ...requestMetadata(fiber.context),
      severity,
    })
  },
)

/**
 * Installs both Inline's explicit boundary reporter and Effect's runtime
 * reporter. Effect deduplicates runtime reports and respects error-level ignore
 * annotations before this adapter is called.
 */
export const ErrorReporterLive = Layer.merge(
  Layer.succeed(ErrorReporter)(inlineReporter),
  EffectErrorReporter.layer([effectReporter]),
)
