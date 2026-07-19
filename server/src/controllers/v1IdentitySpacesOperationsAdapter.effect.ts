import { Effect, Schema } from "effect"
import { omitUndefinedObjectProperties } from "../core/http/jsonResponseCompatibility"
import { InlineError } from "@in/server/types/errors"
import {
  AddMemberResult,
  CheckUsernameResult,
  CreateSpaceResult,
  GetInviteCodesResult,
  GetMeResult,
  GetSpaceMembersResult,
  GetSpaceResult,
  GetSpacesResult,
  GetUserResult,
  LeaveSpaceResult,
  SearchContactsResult,
  UpdateProfilePhotoResult,
  UpdateProfileResult,
  UpdateStatusResult,
  type AddMemberInput,
  type CheckUsernameInput,
  type CreateSpaceInput,
  type DeleteSpaceInput,
  type GetInviteCodesInput,
  type GetMeInput,
  type GetSpaceInput,
  type GetSpaceMembersInput,
  type GetSpacesInput,
  type GetUserInput,
  type LeaveSpaceInput,
  type SavePushNotificationInput,
  type SearchContactsInput,
  type UpdateProfileInput,
  type UpdateProfilePhotoInput,
  type UpdateStatusInput,
} from "./v1IdentitySpacesSchemas.effect"
import {
  V1IdentitySpacesOperationFailure,
  V1IdentitySpacesPublicError,
  V1IdentitySpacesResponseContractFailure,
  type V1IdentitySpacesContext,
  type V1IdentitySpacesOperationError,
  type V1IdentitySpacesOperationsShape,
} from "./v1IdentitySpacesOperations.effect"

export interface LegacyV1IdentitySpacesOperations {
  readonly checkUsername: (input: CheckUsernameInput, context: V1IdentitySpacesContext) => Promise<unknown>
  readonly getMe: (input: GetMeInput, context: V1IdentitySpacesContext) => Promise<unknown>
  readonly getUser: (input: GetUserInput, context: V1IdentitySpacesContext) => Promise<unknown>
  readonly searchContacts: (input: SearchContactsInput, context: V1IdentitySpacesContext) => Promise<unknown>
  readonly updateProfile: (input: UpdateProfileInput, context: V1IdentitySpacesContext) => Promise<unknown>
  readonly updateProfilePhoto: (input: UpdateProfilePhotoInput, context: V1IdentitySpacesContext) => Promise<unknown>
  readonly updateStatus: (input: UpdateStatusInput, context: V1IdentitySpacesContext) => Promise<unknown>
  readonly createSpace: (input: CreateSpaceInput, context: V1IdentitySpacesContext) => Promise<unknown>
  readonly deleteSpace: (input: DeleteSpaceInput, context: V1IdentitySpacesContext) => Promise<unknown>
  readonly getSpaces: (input: GetSpacesInput, context: V1IdentitySpacesContext) => Promise<unknown>
  readonly getSpace: (input: GetSpaceInput, context: V1IdentitySpacesContext) => Promise<unknown>
  readonly getInviteCodes: (input: GetInviteCodesInput, context: V1IdentitySpacesContext) => Promise<unknown>
  readonly addMember: (input: AddMemberInput, context: V1IdentitySpacesContext) => Promise<unknown>
  readonly leaveSpace: (input: LeaveSpaceInput, context: V1IdentitySpacesContext) => Promise<unknown>
  readonly getSpaceMembers: (input: GetSpaceMembersInput, context: V1IdentitySpacesContext) => Promise<unknown>
  readonly savePushNotification: (
    input: SavePushNotificationInput,
    context: V1IdentitySpacesContext,
  ) => Promise<unknown>
}

const publicErrorFromInline = (error: InlineError): V1IdentitySpacesPublicError =>
  new V1IdentitySpacesPublicError({
    error: error.type,
    errorCode: error.code,
    description: error.description,
  })

const mapOperationError = (operation: string, cause: unknown): V1IdentitySpacesOperationError => {
  if (cause instanceof InlineError) {
    const publicError = publicErrorFromInline(cause)
    return cause.code < 500
      ? publicError
      : new V1IdentitySpacesOperationFailure({
          operation,
          cause: cause.cause ?? cause,
          publicError,
        })
  }

  return new V1IdentitySpacesOperationFailure({
    operation,
    cause,
  })
}

const invoke = (
  operation: string,
  run: () => Promise<unknown>,
): Effect.Effect<unknown, V1IdentitySpacesOperationError> =>
  Effect.tryPromise({
    try: run,
    catch: (cause) => mapOperationError(operation, cause),
  })

const decodeResult = <A>(
  operation: string,
  schema: Schema.Decoder<A>,
  value: unknown,
): Effect.Effect<A, V1IdentitySpacesOperationFailure> =>
  Schema.decodeUnknownEffect(schema)(
    omitUndefinedObjectProperties(value),
  ).pipe(
    Effect.mapError(
      () =>
        new V1IdentitySpacesOperationFailure({
          operation,
          cause: new V1IdentitySpacesResponseContractFailure({
            operation,
          }),
        }),
    ),
  )

const invokeAndDecode = <A>(operation: string, schema: Schema.Decoder<A>, run: () => Promise<unknown>) =>
  invoke(operation, run).pipe(Effect.flatMap((result) => decodeResult(`${operation}.response`, schema, result)))

export const makeV1IdentitySpacesOperations = (
  legacy: LegacyV1IdentitySpacesOperations,
): V1IdentitySpacesOperationsShape => ({
  checkUsername: (input, context) =>
    invokeAndDecode("v1.checkUsername", CheckUsernameResult, () => legacy.checkUsername(input, context)),
  getMe: (input, context) => invokeAndDecode("v1.getMe", GetMeResult, () => legacy.getMe(input, context)),
  getUser: (input, context) => invokeAndDecode("v1.getUser", GetUserResult, () => legacy.getUser(input, context)),
  searchContacts: (input, context) =>
    invokeAndDecode("v1.searchContacts", SearchContactsResult, () => legacy.searchContacts(input, context)),
  updateProfile: (input, context) =>
    invokeAndDecode("v1.updateProfile", UpdateProfileResult, () => legacy.updateProfile(input, context)),
  updateProfilePhoto: (input, context) =>
    invokeAndDecode("v1.updateProfilePhoto", UpdateProfilePhotoResult, () => legacy.updateProfilePhoto(input, context)),
  updateStatus: (input, context) =>
    invokeAndDecode("v1.updateStatus", UpdateStatusResult, () => legacy.updateStatus(input, context)),
  createSpace: (input, context) =>
    invokeAndDecode("v1.createSpace", CreateSpaceResult, () => legacy.createSpace(input, context)),
  deleteSpace: (input, context) =>
    invokeAndDecode("v1.deleteSpace", Schema.Undefined, () => legacy.deleteSpace(input, context)),
  getSpaces: (input, context) =>
    invokeAndDecode("v1.getSpaces", GetSpacesResult, () => legacy.getSpaces(input, context)),
  getSpace: (input, context) => invokeAndDecode("v1.getSpace", GetSpaceResult, () => legacy.getSpace(input, context)),
  getInviteCodes: (input, context) =>
    invokeAndDecode("v1.getInviteCodes", GetInviteCodesResult, () => legacy.getInviteCodes(input, context)),
  addMember: (input, context) =>
    invokeAndDecode("v1.addMember", AddMemberResult, () => legacy.addMember(input, context)),
  leaveSpace: (input, context) =>
    invokeAndDecode("v1.leaveSpace", LeaveSpaceResult, () => legacy.leaveSpace(input, context)),
  getSpaceMembers: (input, context) =>
    invokeAndDecode("v1.getSpaceMembers", GetSpaceMembersResult, () => legacy.getSpaceMembers(input, context)),
  savePushNotification: (input, context) =>
    invokeAndDecode("v1.savePushNotification", Schema.Undefined, () => legacy.savePushNotification(input, context)),
})
