import { Effect, Schema } from "effect"
import { omitUndefinedObjectProperties } from "../core/http/jsonResponseCompatibility"
import { InlineError } from "../types/errors"
import {
  V1MessagingProvidersOperationFailure,
  V1MessagingProvidersPublicError,
  V1MessagingProvidersResponseContractFailure,
  type V1MessagingProvidersOperationError,
} from "./v1MessagingProvidersErrors.effect"

const publicErrorFromInline = (error: InlineError): V1MessagingProvidersPublicError =>
  new V1MessagingProvidersPublicError({
    error: error.type,
    errorCode: error.code,
    description: error.description,
  })

const mapOperationError = (operation: string, cause: unknown): V1MessagingProvidersOperationError => {
  if (cause instanceof InlineError) {
    const publicError = publicErrorFromInline(cause)
    return cause.code < 500
      ? publicError
      : new V1MessagingProvidersOperationFailure({
          operation,
          cause: cause.cause ?? cause,
          publicError,
        })
  }

  return new V1MessagingProvidersOperationFailure({
    operation,
    cause,
  })
}

export const invokeLegacyV1Operation = <Output>(
  operation: string,
  resultSchema: Schema.Decoder<Output>,
  run: () => Promise<unknown>,
): Effect.Effect<Output, V1MessagingProvidersOperationError> =>
  Effect.tryPromise({
    try: run,
    catch: (cause) => mapOperationError(operation, cause),
  }).pipe(
    Effect.flatMap((result) =>
      Schema.decodeUnknownEffect(resultSchema)(omitUndefinedObjectProperties(result)).pipe(
        Effect.mapError(
          () =>
            new V1MessagingProvidersOperationFailure({
              operation: `${operation}.response`,
              cause: new V1MessagingProvidersResponseContractFailure({
                operation,
              }),
            }),
        ),
      ),
    ),
  )
