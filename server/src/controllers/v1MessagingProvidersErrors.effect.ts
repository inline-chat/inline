import { Data, ErrorReporter } from "effect"

export class V1MessagingProvidersPublicError extends Data.TaggedError(
  "V1MessagingProvidersPublicError",
)<{
  readonly error: string
  readonly errorCode: number
  readonly description: string | undefined
}> {
  override readonly [ErrorReporter.ignore] = true
}

export class V1MessagingProvidersOperationFailure extends Data.TaggedError(
  "V1MessagingProvidersOperationFailure",
)<{
  readonly operation: string
  readonly cause: unknown
  readonly publicError?: V1MessagingProvidersPublicError | undefined
}> {}

export class V1MessagingProvidersRequestFailure extends Data.TaggedError(
  "V1MessagingProvidersRequestFailure",
)<{
  readonly operation: string
  readonly cause: unknown
}> {}

/**
 * Safe reporter payload for a retained operation returning an undeclared shape.
 *
 * Schema failures can retain request or response values, so the transport
 * reports this marker instead of the parser tree.
 */
export class V1MessagingProvidersResponseContractFailure extends Data.TaggedError(
  "V1MessagingProvidersResponseContractFailure",
)<{
  readonly operation: string
}> {}

export type V1MessagingProvidersOperationError =
  | V1MessagingProvidersPublicError
  | V1MessagingProvidersOperationFailure
