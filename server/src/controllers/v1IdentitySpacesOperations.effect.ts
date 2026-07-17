import { Context, Data, Effect, ErrorReporter } from "effect"
import type {
  AddMemberInput,
  AddMemberResult,
  CheckUsernameInput,
  CheckUsernameResult,
  CreateSpaceInput,
  CreateSpaceResult,
  DeleteSpaceInput,
  GetInviteCodesInput,
  GetInviteCodesResult,
  GetMeInput,
  GetMeResult,
  GetSpaceInput,
  GetSpaceMembersInput,
  GetSpaceMembersResult,
  GetSpaceResult,
  GetSpacesInput,
  GetSpacesResult,
  GetUserInput,
  GetUserResult,
  LeaveSpaceInput,
  LeaveSpaceResult,
  SavePushNotificationInput,
  SearchContactsInput,
  SearchContactsResult,
  UpdateProfileInput,
  UpdateProfilePhotoInput,
  UpdateProfilePhotoResult,
  UpdateProfileResult,
  UpdateStatusInput,
  UpdateStatusResult,
} from "./v1IdentitySpacesSchemas.effect"

export interface V1IdentitySpacesContext {
  readonly currentUserId: number
  readonly currentSessionId: number
  readonly ip: string | undefined
}

export class V1IdentitySpacesPublicError extends Data.TaggedError("V1IdentitySpacesPublicError")<{
  readonly error: string
  readonly errorCode: number
  readonly description: string | undefined
}> {
  override readonly [ErrorReporter.ignore] = true
}

export class V1IdentitySpacesOperationFailure extends Data.TaggedError("V1IdentitySpacesOperationFailure")<{
  readonly operation: string
  readonly cause: unknown
  readonly publicError?: V1IdentitySpacesPublicError | undefined
}> {}

/**
 * Safe reporter payload for a retained method returning an undeclared shape.
 *
 * Schema errors can retain the decoded value and parser tree, so the transport
 * reports this marker rather than user or space data from the invalid result.
 */
export class V1IdentitySpacesResponseContractFailure extends Data.TaggedError(
  "V1IdentitySpacesResponseContractFailure",
)<{
  readonly operation: string
}> {}

export type V1IdentitySpacesOperationError = V1IdentitySpacesPublicError | V1IdentitySpacesOperationFailure

export interface V1IdentitySpacesOperationsShape {
  readonly checkUsername: (
    input: CheckUsernameInput,
    context: V1IdentitySpacesContext,
  ) => Effect.Effect<CheckUsernameResult, V1IdentitySpacesOperationError>
  readonly getMe: (
    input: GetMeInput,
    context: V1IdentitySpacesContext,
  ) => Effect.Effect<GetMeResult, V1IdentitySpacesOperationError>
  readonly getUser: (
    input: GetUserInput,
    context: V1IdentitySpacesContext,
  ) => Effect.Effect<GetUserResult, V1IdentitySpacesOperationError>
  readonly searchContacts: (
    input: SearchContactsInput,
    context: V1IdentitySpacesContext,
  ) => Effect.Effect<SearchContactsResult, V1IdentitySpacesOperationError>
  readonly updateProfile: (
    input: UpdateProfileInput,
    context: V1IdentitySpacesContext,
  ) => Effect.Effect<UpdateProfileResult, V1IdentitySpacesOperationError>
  readonly updateProfilePhoto: (
    input: UpdateProfilePhotoInput,
    context: V1IdentitySpacesContext,
  ) => Effect.Effect<UpdateProfilePhotoResult, V1IdentitySpacesOperationError>
  readonly updateStatus: (
    input: UpdateStatusInput,
    context: V1IdentitySpacesContext,
  ) => Effect.Effect<UpdateStatusResult, V1IdentitySpacesOperationError>
  readonly createSpace: (
    input: CreateSpaceInput,
    context: V1IdentitySpacesContext,
  ) => Effect.Effect<CreateSpaceResult, V1IdentitySpacesOperationError>
  readonly deleteSpace: (
    input: DeleteSpaceInput,
    context: V1IdentitySpacesContext,
  ) => Effect.Effect<void, V1IdentitySpacesOperationError>
  readonly getSpaces: (
    input: GetSpacesInput,
    context: V1IdentitySpacesContext,
  ) => Effect.Effect<GetSpacesResult, V1IdentitySpacesOperationError>
  readonly getSpace: (
    input: GetSpaceInput,
    context: V1IdentitySpacesContext,
  ) => Effect.Effect<GetSpaceResult, V1IdentitySpacesOperationError>
  readonly getInviteCodes: (
    input: GetInviteCodesInput,
    context: V1IdentitySpacesContext,
  ) => Effect.Effect<GetInviteCodesResult, V1IdentitySpacesOperationError>
  readonly addMember: (
    input: AddMemberInput,
    context: V1IdentitySpacesContext,
  ) => Effect.Effect<AddMemberResult, V1IdentitySpacesOperationError>
  readonly leaveSpace: (
    input: LeaveSpaceInput,
    context: V1IdentitySpacesContext,
  ) => Effect.Effect<LeaveSpaceResult, V1IdentitySpacesOperationError>
  readonly getSpaceMembers: (
    input: GetSpaceMembersInput,
    context: V1IdentitySpacesContext,
  ) => Effect.Effect<GetSpaceMembersResult, V1IdentitySpacesOperationError>
  readonly savePushNotification: (
    input: SavePushNotificationInput,
    context: V1IdentitySpacesContext,
  ) => Effect.Effect<void, V1IdentitySpacesOperationError>
}

export class V1IdentitySpacesOperations extends Context.Service<
  V1IdentitySpacesOperations,
  V1IdentitySpacesOperationsShape
>()("@inline/server/v1/V1IdentitySpacesOperations") {}
