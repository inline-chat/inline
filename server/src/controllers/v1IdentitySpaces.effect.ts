import { Cause, Effect, Schema } from "effect"
import { HttpServerRequest, HttpServerResponse } from "effect/unstable/http"
import { HttpApiBuilder, HttpApiEndpoint, HttpApiGroup, HttpApiSchema } from "effect/unstable/httpapi"
import { normalizeToken } from "@in/server/utils/auth"
import { recordApiError } from "@in/server/utils/metrics"
import { reportUnexpectedError } from "../core/errors/errorReporter"
import { parseLegacyElysiaBody } from "../core/http/legacyElysiaBody"
import { makePlatformApiBase, PLATFORM_API_ID, requireOpenApiRequestHeader } from "../core/http/openApi"
import { HttpRequestContext } from "../core/http/requestContext"
import { defineHttpRouteGroup } from "../core/http/routeGroup"
import {
  missingSessionAuthentication,
  SessionAuthentication,
  type SessionAuthenticationRejected,
} from "./plugins.effect"
import {
  V1IdentitySpacesOperationFailure,
  V1IdentitySpacesOperations,
  type V1IdentitySpacesContext,
  type V1IdentitySpacesOperationsShape,
  type V1IdentitySpacesPublicError,
} from "./v1IdentitySpacesOperations.effect"
import {
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
  V1IdentitySpacesEmptySuccess,
  v1IdentitySpacesApiErrorAt,
  v1IdentitySpacesSuccess,
} from "./v1IdentitySpacesSchemas.effect"

const v1Errors = [
  v1IdentitySpacesApiErrorAt(400),
  v1IdentitySpacesApiErrorAt(401),
  v1IdentitySpacesApiErrorAt(403),
  v1IdentitySpacesApiErrorAt(420),
  v1IdentitySpacesApiErrorAt(500),
] as const

const CheckUsernameSuccess = v1IdentitySpacesSuccess(CheckUsernameResult).annotate({
  identifier: "CheckUsernameSuccess",
})
const GetMeSuccess = v1IdentitySpacesSuccess(GetMeResult).annotate({ identifier: "GetMeSuccess" })
const GetUserSuccess = v1IdentitySpacesSuccess(GetUserResult).annotate({ identifier: "GetUserSuccess" })
const SearchContactsSuccess = v1IdentitySpacesSuccess(SearchContactsResult).annotate({
  identifier: "SearchContactsSuccess",
})
const UpdateProfileSuccess = v1IdentitySpacesSuccess(UpdateProfileResult).annotate({
  identifier: "UpdateProfileSuccess",
})
const UpdateProfilePhotoSuccess = v1IdentitySpacesSuccess(UpdateProfilePhotoResult).annotate({
  identifier: "UpdateProfilePhotoSuccess",
})
const UpdateStatusSuccess = v1IdentitySpacesSuccess(UpdateStatusResult).annotate({ identifier: "UpdateStatusSuccess" })
const CreateSpaceSuccess = v1IdentitySpacesSuccess(CreateSpaceResult).annotate({ identifier: "CreateSpaceSuccess" })
const GetSpacesSuccess = v1IdentitySpacesSuccess(GetSpacesResult).annotate({ identifier: "GetSpacesSuccess" })
const GetSpaceSuccess = v1IdentitySpacesSuccess(GetSpaceResult).annotate({ identifier: "GetSpaceSuccess" })
const GetInviteCodesSuccess = v1IdentitySpacesSuccess(GetInviteCodesResult).annotate({
  identifier: "GetInviteCodesSuccess",
})
const AddMemberSuccess = v1IdentitySpacesSuccess(AddMemberResult).annotate({ identifier: "AddMemberSuccess" })
const LeaveSpaceSuccess = v1IdentitySpacesSuccess(LeaveSpaceResult).annotate({ identifier: "LeaveSpaceSuccess" })
const GetSpaceMembersSuccess = v1IdentitySpacesSuccess(GetSpaceMembersResult).annotate({
  identifier: "GetSpaceMembersSuccess",
})

const AuthorizationHeader = {
  authorization: Schema.optionalKey(Schema.String),
} as const

const legacyPostPayloads = <S extends Schema.Top>(schema: S) =>
  [schema, schema.pipe(HttpApiSchema.asFormUrlEncoded()), schema.pipe(HttpApiSchema.asMultipart())] as const

const authenticatedEndpoints = <
  Name extends string,
  Method extends string,
  Fields extends Record<string, Schema.Top>,
  Success extends Schema.Top,
>(
  name: Name,
  method: Method,
  input: Schema.Struct<Fields>,
  success: Success,
) => {
  const path = `/v1/${method}` as const
  const tokenPath = `/v1/:token/${method}` as const
  const headerDescription = "Required session token using the Bearer scheme."

  return [
    HttpApiEndpoint.get(`get${name}`, path, {
      headers: AuthorizationHeader,
      payload: input.fields,
      success,
      error: v1Errors,
    }).annotateMerge(requireOpenApiRequestHeader("authorization", headerDescription)),
    HttpApiEndpoint.get(`get${name}WithToken`, tokenPath, {
      params: { token: Schema.String },
      payload: input.fields,
      success,
      error: v1Errors,
    }),
    HttpApiEndpoint.post(`post${name}`, path, {
      headers: AuthorizationHeader,
      payload: legacyPostPayloads(input),
      success,
      error: v1Errors,
    }).annotateMerge(requireOpenApiRequestHeader("authorization", headerDescription)),
  ] as const
}

const CheckUsernameEndpoints = authenticatedEndpoints(
  "CheckUsername",
  "checkUsername",
  CheckUsernameInput,
  CheckUsernameSuccess,
)
const GetMeEndpoints = authenticatedEndpoints("GetMe", "getMe", GetMeInput, GetMeSuccess)
const GetUserEndpoints = authenticatedEndpoints("GetUser", "getUser", GetUserInput, GetUserSuccess)
const SearchContactsEndpoints = authenticatedEndpoints(
  "SearchContacts",
  "searchContacts",
  SearchContactsInput,
  SearchContactsSuccess,
)
const UpdateProfileEndpoints = authenticatedEndpoints(
  "UpdateProfile",
  "updateProfile",
  UpdateProfileInput,
  UpdateProfileSuccess,
)
const UpdateProfilePhotoEndpoints = authenticatedEndpoints(
  "UpdateProfilePhoto",
  "updateProfilePhoto",
  UpdateProfilePhotoInput,
  UpdateProfilePhotoSuccess,
)
const UpdateStatusEndpoints = authenticatedEndpoints(
  "UpdateStatus",
  "updateStatus",
  UpdateStatusInput,
  UpdateStatusSuccess,
)
const CreateSpaceEndpoints = authenticatedEndpoints("CreateSpace", "createSpace", CreateSpaceInput, CreateSpaceSuccess)
const DeleteSpaceEndpoints = authenticatedEndpoints(
  "DeleteSpace",
  "deleteSpace",
  DeleteSpaceInput,
  V1IdentitySpacesEmptySuccess,
)
const GetSpacesEndpoints = authenticatedEndpoints("GetSpaces", "getSpaces", GetSpacesInput, GetSpacesSuccess)
const GetSpaceEndpoints = authenticatedEndpoints("GetSpace", "getSpace", GetSpaceInput, GetSpaceSuccess)
const GetInviteCodesEndpoints = authenticatedEndpoints(
  "GetInviteCodes",
  "getInviteCodes",
  GetInviteCodesInput,
  GetInviteCodesSuccess,
)
const AddMemberEndpoints = authenticatedEndpoints("AddMember", "addMember", AddMemberInput, AddMemberSuccess)
const LeaveSpaceEndpoints = authenticatedEndpoints("LeaveSpace", "leaveSpace", LeaveSpaceInput, LeaveSpaceSuccess)
const GetSpaceMembersEndpoints = authenticatedEndpoints(
  "GetSpaceMembers",
  "getSpaceMembers",
  GetSpaceMembersInput,
  GetSpaceMembersSuccess,
)
const SavePushNotificationEndpoints = authenticatedEndpoints(
  "SavePushNotification",
  "savePushNotification",
  SavePushNotificationInput,
  V1IdentitySpacesEmptySuccess,
)

export const V1IdentitySpacesApiGroup = HttpApiGroup.make("v1IdentitySpaces").add(
  ...CheckUsernameEndpoints,
  ...GetMeEndpoints,
  ...GetUserEndpoints,
  ...SearchContactsEndpoints,
  ...UpdateProfileEndpoints,
  ...UpdateProfilePhotoEndpoints,
  ...UpdateStatusEndpoints,
  ...CreateSpaceEndpoints,
  ...DeleteSpaceEndpoints,
  ...GetSpacesEndpoints,
  ...GetSpaceEndpoints,
  ...GetInviteCodesEndpoints,
  ...AddMemberEndpoints,
  ...LeaveSpaceEndpoints,
  ...GetSpaceMembersEndpoints,
  ...SavePushNotificationEndpoints,
)

export type V1IdentitySpacesOperation =
  | "checkUsername"
  | "getMe"
  | "getUser"
  | "searchContacts"
  | "updateProfile"
  | "updateProfilePhoto"
  | "updateStatus"
  | "createSpace"
  | "deleteSpace"
  | "getSpaces"
  | "getSpace"
  | "getInviteCodes"
  | "addMember"
  | "leaveSpace"
  | "getSpaceMembers"
  | "savePushNotification"

const json = (status: number, body: unknown): HttpServerResponse.HttpServerResponse =>
  HttpServerResponse.jsonUnsafe(body, { status })

const noteApiError = Effect.sync(() => {
  try {
    recordApiError()
  } catch {
    // Metrics must not replace the response being emitted.
  }
})

const validationError = () =>
  json(400, {
    ok: false,
    error: "INVALID_ARGS",
    errorCode: 400,
    description: "Validation error",
  })

const publicErrorResponse = (error: V1IdentitySpacesPublicError | SessionAuthenticationRejected) =>
  json(error.errorCode, {
    ok: false,
    error: error.error,
    errorCode: error.errorCode,
    description: error.description,
  })

const serverErrorResponse = () =>
  json(500, {
    ok: false,
    error: "SERVER_ERROR",
    errorCode: 500,
    description: "Server error",
  })

const reportFailure = (operation: string, cause: unknown) =>
  Effect.gen(function* () {
    const context = yield* HttpRequestContext
    yield* reportUnexpectedError({
      cause: Cause.fail(cause),
      context: {
        operation,
        requestId: context.requestId,
      },
    })
  })

const completeOperation = <A>(
  operation: string,
  effect: Effect.Effect<A, V1IdentitySpacesPublicError | V1IdentitySpacesOperationFailure>,
  success: (value: A) => unknown,
) =>
  effect.pipe(
    Effect.matchEffect({
      onFailure: (error) =>
        noteApiError.pipe(
          Effect.andThen(
            error._tag === "V1IdentitySpacesPublicError"
              ? Effect.succeed(publicErrorResponse(error))
              : reportFailure(error.operation, error.cause).pipe(
                  Effect.as(
                    error.publicError === undefined ? serverErrorResponse() : publicErrorResponse(error.publicError),
                  ),
                ),
          ),
        ),
      onSuccess: (value) => Effect.succeed(json(200, success(value))),
    }),
    Effect.annotateLogs({
      "v1.operation": operation,
    }),
  )

const decodeAndRun = <Input, Output>(
  operation: string,
  schema: Schema.Decoder<Input>,
  rawInput: unknown,
  run: (input: Input) => Effect.Effect<Output, V1IdentitySpacesPublicError | V1IdentitySpacesOperationFailure>,
  success: (value: Output) => unknown = (result) => ({
    ok: true,
    result,
  }),
) =>
  Schema.decodeUnknownEffect(schema)(rawInput).pipe(
    Effect.matchEffect({
      onFailure: () => noteApiError.pipe(Effect.as(validationError())),
      onSuccess: (input) => completeOperation(operation, run(input), success),
    }),
  )

const runOperation = (
  operation: V1IdentitySpacesOperation,
  input: unknown,
  context: V1IdentitySpacesContext,
  operations: V1IdentitySpacesOperationsShape,
) => {
  switch (operation) {
    case "checkUsername":
      return decodeAndRun("v1.checkUsername", CheckUsernameInput, input, (decoded) =>
        operations.checkUsername(decoded, context),
      )
    case "getMe":
      return decodeAndRun("v1.getMe", GetMeInput, input, (decoded) => operations.getMe(decoded, context))
    case "getUser":
      return decodeAndRun("v1.getUser", GetUserInput, input, (decoded) => operations.getUser(decoded, context))
    case "searchContacts":
      return decodeAndRun("v1.searchContacts", SearchContactsInput, input, (decoded) =>
        operations.searchContacts(decoded, context),
      )
    case "updateProfile":
      return decodeAndRun("v1.updateProfile", UpdateProfileInput, input, (decoded) =>
        operations.updateProfile(decoded, context),
      )
    case "updateProfilePhoto":
      return decodeAndRun("v1.updateProfilePhoto", UpdateProfilePhotoInput, input, (decoded) =>
        operations.updateProfilePhoto(decoded, context),
      )
    case "updateStatus":
      return decodeAndRun("v1.updateStatus", UpdateStatusInput, input, (decoded) =>
        operations.updateStatus(decoded, context),
      )
    case "createSpace":
      return decodeAndRun("v1.createSpace", CreateSpaceInput, input, (decoded) =>
        operations.createSpace(decoded, context),
      )
    case "deleteSpace":
      return decodeAndRun(
        "v1.deleteSpace",
        DeleteSpaceInput,
        input,
        (decoded) => operations.deleteSpace(decoded, context),
        () => ({ ok: true }),
      )
    case "getSpaces":
      return decodeAndRun("v1.getSpaces", GetSpacesInput, input, (decoded) => operations.getSpaces(decoded, context))
    case "getSpace":
      return decodeAndRun("v1.getSpace", GetSpaceInput, input, (decoded) => operations.getSpace(decoded, context))
    case "getInviteCodes":
      return decodeAndRun("v1.getInviteCodes", GetInviteCodesInput, input, (decoded) =>
        operations.getInviteCodes(decoded, context),
      )
    case "addMember":
      return decodeAndRun("v1.addMember", AddMemberInput, input, (decoded) => operations.addMember(decoded, context))
    case "leaveSpace":
      return decodeAndRun("v1.leaveSpace", LeaveSpaceInput, input, (decoded) => operations.leaveSpace(decoded, context))
    case "getSpaceMembers":
      return decodeAndRun("v1.getSpaceMembers", GetSpaceMembersInput, input, (decoded) =>
        operations.getSpaceMembers(decoded, context),
      )
    case "savePushNotification":
      return decodeAndRun(
        "v1.savePushNotification",
        SavePushNotificationInput,
        input,
        (decoded) => operations.savePushNotification(decoded, context),
        () => ({ ok: true }),
      )
  }
}

const InvalidV1Payload = Symbol("InvalidV1Payload")

const normalizeIntegerInput = (operation: V1IdentitySpacesOperation, input: unknown): unknown => {
  if (operation !== "searchContacts" || input === null || typeof input !== "object" || Array.isArray(input)) {
    return input
  }

  const record = input as Record<string, unknown>
  return typeof record["limit"] === "string"
    ? {
        ...record,
        limit: Number(record["limit"]),
      }
    : input
}

const bodyToInput = async (request: Request, operation: V1IdentitySpacesOperation): Promise<unknown> => {
  if (request.method === "GET") {
    const input = Object.fromEntries(new URL(request.url).searchParams)

    if (operation === "updateStatus" && typeof input["online"] === "string") {
      return {
        ...input,
        online: input["online"] === "true" ? true : input["online"] === "false" ? false : input["online"],
      }
    }

    return normalizeIntegerInput(operation, input)
  }

  return normalizeIntegerInput(operation, await parseLegacyElysiaBody(request))
}

const prepareRequest = (request: HttpServerRequest.HttpServerRequest, operation: V1IdentitySpacesOperation) =>
  HttpServerRequest.toWeb(request).pipe(
    Effect.flatMap((webRequest) =>
      Effect.tryPromise({
        try: () => bodyToInput(webRequest, operation),
        catch: () => InvalidV1Payload,
      }).pipe(Effect.map((input) => ({ input, webRequest }))),
    ),
  )

const authenticate = (request: Request, pathToken: string | undefined) => {
  const token = normalizeToken(pathToken ?? request.headers.get("authorization") ?? undefined)

  return token === null
    ? Effect.fail(missingSessionAuthentication())
    : SessionAuthentication.use((service) => service.authenticate(token))
}

/**
 * Decode before authentication so malformed requests cannot touch session
 * storage. `runOperation` performs the same deterministic schema decode again
 * to recover the operation-specific static type before invoking its service.
 */
const decodeInput = (
  operation: V1IdentitySpacesOperation,
  input: unknown,
): Effect.Effect<unknown, Schema.SchemaError> => {
  switch (operation) {
    case "checkUsername":
      return Schema.decodeUnknownEffect(CheckUsernameInput)(input)
    case "getMe":
      return Schema.decodeUnknownEffect(GetMeInput)(input)
    case "getUser":
      return Schema.decodeUnknownEffect(GetUserInput)(input)
    case "searchContacts":
      return Schema.decodeUnknownEffect(SearchContactsInput)(input)
    case "updateProfile":
      return Schema.decodeUnknownEffect(UpdateProfileInput)(input)
    case "updateProfilePhoto":
      return Schema.decodeUnknownEffect(UpdateProfilePhotoInput)(input)
    case "updateStatus":
      return Schema.decodeUnknownEffect(UpdateStatusInput)(input)
    case "createSpace":
      return Schema.decodeUnknownEffect(CreateSpaceInput)(input)
    case "deleteSpace":
      return Schema.decodeUnknownEffect(DeleteSpaceInput)(input)
    case "getSpaces":
      return Schema.decodeUnknownEffect(GetSpacesInput)(input)
    case "getSpace":
      return Schema.decodeUnknownEffect(GetSpaceInput)(input)
    case "getInviteCodes":
      return Schema.decodeUnknownEffect(GetInviteCodesInput)(input)
    case "addMember":
      return Schema.decodeUnknownEffect(AddMemberInput)(input)
    case "leaveSpace":
      return Schema.decodeUnknownEffect(LeaveSpaceInput)(input)
    case "getSpaceMembers":
      return Schema.decodeUnknownEffect(GetSpaceMembersInput)(input)
    case "savePushNotification":
      return Schema.decodeUnknownEffect(SavePushNotificationInput)(input)
  }
}

export const executeV1IdentitySpaces = (
  operation: V1IdentitySpacesOperation,
  request: HttpServerRequest.HttpServerRequest,
  options: {
    readonly pathToken?: string | undefined
  } = {},
) =>
  prepareRequest(request, operation).pipe(
    Effect.flatMap(({ input, webRequest }) =>
      decodeInput(operation, input).pipe(
        Effect.matchEffect({
          onFailure: () => noteApiError.pipe(Effect.as(validationError())),
          onSuccess: (decodedInput) =>
            authenticate(webRequest, options.pathToken).pipe(
              Effect.matchEffect({
                onFailure: (error) =>
                  noteApiError.pipe(
                    Effect.andThen(
                      error._tag === "SessionAuthenticationRejected"
                        ? Effect.succeed(publicErrorResponse(error))
                        : reportFailure("v1.authenticate", error.cause).pipe(Effect.as(serverErrorResponse())),
                    ),
                  ),
                onSuccess: (identity) =>
                  HttpRequestContext.use((requestContext) =>
                    V1IdentitySpacesOperations.use((operations) =>
                      runOperation(
                        operation,
                        decodedInput,
                        {
                          currentUserId: identity.userId,
                          currentSessionId: identity.sessionId,
                          ip: requestContext.clientIp,
                        },
                        operations,
                      ),
                    ),
                  ),
              }),
            ),
        }),
      ),
    ),
    Effect.catch((cause) =>
      cause === InvalidV1Payload
        ? noteApiError.pipe(Effect.as(serverErrorResponse()))
        : reportFailure(`v1.${operation}.request`, cause).pipe(Effect.as(serverErrorResponse())),
    ),
  )

export const makeV1IdentitySpacesRouteGroup = () => {
  const api = makePlatformApiBase("https://api.inline.chat").add(V1IdentitySpacesApiGroup)
  const handlers = HttpApiBuilder.group(api, "v1IdentitySpaces", (groupHandlers) =>
    Effect.gen(function* () {
      const services = yield* Effect.context<V1IdentitySpacesOperations | SessionAuthentication>()
      const execute = (
        operation: V1IdentitySpacesOperation,
        request: HttpServerRequest.HttpServerRequest,
        options?: {
          readonly pathToken?: string | undefined
        },
      ) => Effect.provide(executeV1IdentitySpaces(operation, request, options), services)

      return groupHandlers
        .handleRaw("getCheckUsername", ({ request }) => execute("checkUsername", request))
        .handleRaw("getCheckUsernameWithToken", ({ params, request }) =>
          execute("checkUsername", request, {
            pathToken: params.token,
          }),
        )
        .handleRaw("postCheckUsername", ({ request }) => execute("checkUsername", request))
        .handleRaw("getGetMe", ({ request }) => execute("getMe", request))
        .handleRaw("getGetMeWithToken", ({ params, request }) =>
          execute("getMe", request, {
            pathToken: params.token,
          }),
        )
        .handleRaw("postGetMe", ({ request }) => execute("getMe", request))
        .handleRaw("getGetUser", ({ request }) => execute("getUser", request))
        .handleRaw("getGetUserWithToken", ({ params, request }) =>
          execute("getUser", request, {
            pathToken: params.token,
          }),
        )
        .handleRaw("postGetUser", ({ request }) => execute("getUser", request))
        .handleRaw("getSearchContacts", ({ request }) => execute("searchContacts", request))
        .handleRaw("getSearchContactsWithToken", ({ params, request }) =>
          execute("searchContacts", request, {
            pathToken: params.token,
          }),
        )
        .handleRaw("postSearchContacts", ({ request }) => execute("searchContacts", request))
        .handleRaw("getUpdateProfile", ({ request }) => execute("updateProfile", request))
        .handleRaw("getUpdateProfileWithToken", ({ params, request }) =>
          execute("updateProfile", request, {
            pathToken: params.token,
          }),
        )
        .handleRaw("postUpdateProfile", ({ request }) => execute("updateProfile", request))
        .handleRaw("getUpdateProfilePhoto", ({ request }) => execute("updateProfilePhoto", request))
        .handleRaw("getUpdateProfilePhotoWithToken", ({ params, request }) =>
          execute("updateProfilePhoto", request, {
            pathToken: params.token,
          }),
        )
        .handleRaw("postUpdateProfilePhoto", ({ request }) => execute("updateProfilePhoto", request))
        .handleRaw("getUpdateStatus", ({ request }) => execute("updateStatus", request))
        .handleRaw("getUpdateStatusWithToken", ({ params, request }) =>
          execute("updateStatus", request, {
            pathToken: params.token,
          }),
        )
        .handleRaw("postUpdateStatus", ({ request }) => execute("updateStatus", request))
        .handleRaw("getCreateSpace", ({ request }) => execute("createSpace", request))
        .handleRaw("getCreateSpaceWithToken", ({ params, request }) =>
          execute("createSpace", request, {
            pathToken: params.token,
          }),
        )
        .handleRaw("postCreateSpace", ({ request }) => execute("createSpace", request))
        .handleRaw("getDeleteSpace", ({ request }) => execute("deleteSpace", request))
        .handleRaw("getDeleteSpaceWithToken", ({ params, request }) =>
          execute("deleteSpace", request, {
            pathToken: params.token,
          }),
        )
        .handleRaw("postDeleteSpace", ({ request }) => execute("deleteSpace", request))
        .handleRaw("getGetSpaces", ({ request }) => execute("getSpaces", request))
        .handleRaw("getGetSpacesWithToken", ({ params, request }) =>
          execute("getSpaces", request, {
            pathToken: params.token,
          }),
        )
        .handleRaw("postGetSpaces", ({ request }) => execute("getSpaces", request))
        .handleRaw("getGetSpace", ({ request }) => execute("getSpace", request))
        .handleRaw("getGetSpaceWithToken", ({ params, request }) =>
          execute("getSpace", request, {
            pathToken: params.token,
          }),
        )
        .handleRaw("postGetSpace", ({ request }) => execute("getSpace", request))
        .handleRaw("getGetInviteCodes", ({ request }) => execute("getInviteCodes", request))
        .handleRaw("getGetInviteCodesWithToken", ({ params, request }) =>
          execute("getInviteCodes", request, {
            pathToken: params.token,
          }),
        )
        .handleRaw("postGetInviteCodes", ({ request }) => execute("getInviteCodes", request))
        .handleRaw("getAddMember", ({ request }) => execute("addMember", request))
        .handleRaw("getAddMemberWithToken", ({ params, request }) =>
          execute("addMember", request, {
            pathToken: params.token,
          }),
        )
        .handleRaw("postAddMember", ({ request }) => execute("addMember", request))
        .handleRaw("getLeaveSpace", ({ request }) => execute("leaveSpace", request))
        .handleRaw("getLeaveSpaceWithToken", ({ params, request }) =>
          execute("leaveSpace", request, {
            pathToken: params.token,
          }),
        )
        .handleRaw("postLeaveSpace", ({ request }) => execute("leaveSpace", request))
        .handleRaw("getGetSpaceMembers", ({ request }) => execute("getSpaceMembers", request))
        .handleRaw("getGetSpaceMembersWithToken", ({ params, request }) =>
          execute("getSpaceMembers", request, {
            pathToken: params.token,
          }),
        )
        .handleRaw("postGetSpaceMembers", ({ request }) => execute("getSpaceMembers", request))
        .handleRaw("getSavePushNotification", ({ request }) => execute("savePushNotification", request))
        .handleRaw("getSavePushNotificationWithToken", ({ params, request }) =>
          execute("savePushNotification", request, {
            pathToken: params.token,
          }),
        )
        .handleRaw("postSavePushNotification", ({ request }) => execute("savePushNotification", request))
    }),
  )

  return defineHttpRouteGroup({
    apiId: PLATFORM_API_ID,
    document: "platform",
    group: V1IdentitySpacesApiGroup,
    handlers,
  })
}

export const V1IdentitySpacesRouteGroup = makeV1IdentitySpacesRouteGroup()
