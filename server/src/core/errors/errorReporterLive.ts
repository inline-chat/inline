import {
  Context,
  Effect,
  ErrorReporter as EffectErrorReporter,
  Layer,
  Option,
} from "effect"
import { HttpApiError } from "effect/unstable/httpapi"
import { Log } from "@in/server/utils/log"
import {
  ErrorReporter,
  type ErrorReporterShape,
} from "./errorReporter"
import { effectCauseDiagnostic } from "./effectCauseDiagnostics"
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
      const diagnostic = effectCauseDiagnostic(cause)
      safeLogError("Unexpected Effect failure", diagnostic.error, {
        ...context,
        effectCause: diagnostic.metadata,
      })
    }),
}

const effectReporter = EffectErrorReporter.make(
  ({ error, severity, attributes, fiber }) => {
    const metadata = {
      ...attributes,
      ...requestMetadata(fiber.context),
      severity,
    }
    // A request that fails schema decoding is the caller's 400, not a server
    // fault. Effect leaves HttpApiSchemaError unannotated, unlike its other
    // HttpApiError classes, so it would otherwise surface as a Sentry issue.
    if (HttpApiError.HttpApiSchemaError.is(error)) {
      try {
        log.warn("Rejected malformed HTTP request", { ...metadata, kind: error.kind })
      } catch {
        // Observability must never replace the failure it is reporting.
      }
      return
    }
    safeLogError("Effect boundary failure", error, metadata)
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
