import {
  Context,
  Data,
  Effect,
  ErrorReporter,
} from "effect"
import {
  CheckInviteCodeResult,
  type CheckInviteCodeInput,
  type LoginSessionResult as LoginSessionResultType,
  type SendEmailCodeInput,
  type SendEmailCodeResult as SendEmailCodeResultType,
  type SendSmsCodeInput,
  type SendSmsCodeResult as SendSmsCodeResultType,
  type VerifyEmailCodeInput,
  type VerifySmsCodeInput,
} from "./identitySchemas.effect"

export interface UnauthenticatedIdentityContext {
  readonly ip: string | undefined
  readonly source: string
}

export interface AuthenticatedIdentityContext {
  readonly currentUserId: number
  readonly currentSessionId: number
  readonly ip: string | undefined
}

export class IdentityPublicError extends Data.TaggedError(
  "IdentityPublicError",
)<{
  readonly error: string
  readonly errorCode: number
  readonly description: string | undefined
}> {
  override readonly [ErrorReporter.ignore] = true
}

export class IdentityOperationFailure extends Data.TaggedError(
  "IdentityOperationFailure",
)<{
  readonly operation: string
  readonly cause: unknown
  readonly publicError?: IdentityPublicError | undefined
}> {}

type IdentityOperationError =
  | IdentityPublicError
  | IdentityOperationFailure

export interface IdentityOperationsShape {
  readonly sendSmsCode: (
    input: SendSmsCodeInput,
    context: UnauthenticatedIdentityContext,
  ) => Effect.Effect<SendSmsCodeResultType, IdentityOperationError>
  readonly verifySmsCode: (
    input: VerifySmsCodeInput,
    context: UnauthenticatedIdentityContext,
  ) => Effect.Effect<LoginSessionResultType, IdentityOperationError>
  readonly sendEmailCode: (
    input: SendEmailCodeInput,
    context: UnauthenticatedIdentityContext,
  ) => Effect.Effect<SendEmailCodeResultType, IdentityOperationError>
  readonly verifyEmailCode: (
    input: VerifyEmailCodeInput,
    context: UnauthenticatedIdentityContext,
  ) => Effect.Effect<LoginSessionResultType, IdentityOperationError>
  readonly checkInviteCode: (
    input: CheckInviteCodeInput,
    context: UnauthenticatedIdentityContext,
  ) => Effect.Effect<
    typeof CheckInviteCodeResult.Type,
    IdentityOperationError
  >
  readonly logout: (
    context: AuthenticatedIdentityContext,
  ) => Effect.Effect<void, IdentityOperationError>
}

export class IdentityOperations extends Context.Service<
  IdentityOperations,
  IdentityOperationsShape
>()("@inline/server/auth/IdentityOperations") {}
