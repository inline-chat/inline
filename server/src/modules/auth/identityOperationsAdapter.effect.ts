import {
  Effect,
  Schema,
} from "effect"
import {
  omitUndefinedObjectProperties,
} from "@in/server/core/http/jsonResponseCompatibility"
import { InlineError } from "@in/server/types/errors"
import {
  CheckInviteCodeResult,
  LoginSessionResult,
  SendEmailCodeResult,
  SendSmsCodeResult,
  type CheckInviteCodeInput,
  type SendEmailCodeInput,
  type SendSmsCodeInput,
  type VerifyEmailCodeInput,
  type VerifySmsCodeInput,
} from "./identitySchemas.effect"
import {
  IdentityOperationFailure,
  IdentityPublicError,
  type AuthenticatedIdentityContext,
  type IdentityOperationsShape,
  type UnauthenticatedIdentityContext,
} from "./identityOperations.effect"

export interface LegacyIdentityOperations {
  readonly sendSmsCode: (
    input: SendSmsCodeInput,
    context: UnauthenticatedIdentityContext,
  ) => Promise<unknown>
  readonly verifySmsCode: (
    input: VerifySmsCodeInput,
    context: UnauthenticatedIdentityContext,
  ) => Promise<unknown>
  readonly sendEmailCode: (
    input: SendEmailCodeInput,
    context: UnauthenticatedIdentityContext,
  ) => Promise<unknown>
  readonly verifyEmailCode: (
    input: VerifyEmailCodeInput,
    context: UnauthenticatedIdentityContext,
  ) => Promise<unknown>
  readonly checkInviteCode: (
    input: CheckInviteCodeInput,
    context: UnauthenticatedIdentityContext,
  ) => Promise<unknown>
  readonly logout: (
    context: AuthenticatedIdentityContext,
  ) => Promise<unknown>
}

type IdentityOperationError =
  | IdentityPublicError
  | IdentityOperationFailure

const publicErrorFromInline = (
  error: InlineError,
): IdentityPublicError =>
  new IdentityPublicError({
    error: error.type,
    errorCode: error.code,
    description: error.description,
  })

const mapOperationError = (
  operation: string,
  cause: unknown,
): IdentityOperationError => {
  if (cause instanceof InlineError) {
    const publicError = publicErrorFromInline(cause)
    return cause.code < 500
      ? publicError
      : new IdentityOperationFailure({
          operation,
          cause: cause.cause ?? cause,
          publicError,
        })
  }

  return new IdentityOperationFailure({
    operation,
    cause,
  })
}

const invoke = (
  operation: string,
  run: () => Promise<unknown>,
): Effect.Effect<unknown, IdentityOperationError> =>
  Effect.tryPromise({
    try: run,
    catch: (cause) => mapOperationError(operation, cause),
  })

const decodeResult = <A>(
  operation: string,
  schema: Schema.Decoder<A>,
  value: unknown,
): Effect.Effect<A, IdentityOperationFailure> =>
  Schema.decodeUnknownEffect(schema)(
    omitUndefinedObjectProperties(value),
  ).pipe(
    Effect.mapError(
      (cause) =>
        new IdentityOperationFailure({
          operation,
          cause,
        }),
    ),
  )

export const makeIdentityOperations = (
  legacy: LegacyIdentityOperations,
): IdentityOperationsShape => ({
  sendSmsCode: (input, context) =>
    invoke(
      "identity.sendSmsCode",
      () => legacy.sendSmsCode(input, context),
    ).pipe(
      Effect.flatMap((result) =>
        decodeResult(
          "identity.sendSmsCode.response",
          SendSmsCodeResult,
          result,
        ),
      ),
    ),
  verifySmsCode: (input, context) =>
    invoke(
      "identity.verifySmsCode",
      () => legacy.verifySmsCode(input, context),
    ).pipe(
      Effect.flatMap((result) =>
        decodeResult(
          "identity.verifySmsCode.response",
          LoginSessionResult,
          result,
        ),
      ),
    ),
  sendEmailCode: (input, context) =>
    invoke(
      "identity.sendEmailCode",
      () => legacy.sendEmailCode(input, context),
    ).pipe(
      Effect.flatMap((result) =>
        decodeResult(
          "identity.sendEmailCode.response",
          SendEmailCodeResult,
          result,
        ),
      ),
    ),
  verifyEmailCode: (input, context) =>
    invoke(
      "identity.verifyEmailCode",
      () => legacy.verifyEmailCode(input, context),
    ).pipe(
      Effect.flatMap((result) =>
        decodeResult(
          "identity.verifyEmailCode.response",
          LoginSessionResult,
          result,
        ),
      ),
    ),
  checkInviteCode: (input, context) =>
    invoke(
      "identity.checkInviteCode",
      () => legacy.checkInviteCode(input, context),
    ).pipe(
      Effect.flatMap((result) =>
        decodeResult(
          "identity.checkInviteCode.response",
          CheckInviteCodeResult,
          result,
        ),
      ),
    ),
  logout: (context) =>
    invoke(
      "identity.logout",
      () => legacy.logout(context),
    ).pipe(Effect.asVoid),
})
