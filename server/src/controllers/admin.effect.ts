import {
  Effect,
} from "effect"
import {
  HttpServerResponse,
} from "effect/unstable/http"
import {
  HttpApiBuilder,
  HttpApiEndpoint,
  HttpApiGroup,
  OpenApi,
} from "effect/unstable/httpapi"
import {
  ErrorReporter,
} from "../core/errors/errorReporter"
import {
  makePlatformApiBase,
  PLATFORM_API_ID,
} from "../core/http/openApi"
import {
  defineHttpRouteGroup,
} from "../core/http/routeGroup"
import {
  AdminOperations,
} from "./adminOperations.effect"
import {
  AdminAvatarAuthentication,
  AdminAvatarOriginGuard,
  AdminAvatarSetupComplete,
  AdminAuthentication,
  AdminOriginGuard,
  AdminRecentStepUp,
  AdminSetupComplete,
} from "./adminSecurity.effect"
import {
  adminRequestInfo as infoOnly,
  completeAdminRequest as complete,
  decodeAdminBody as decodeBody,
  decodeAdminPathParam as decodePathParam,
  decodeAdminQuery as decodeQuery,
  withAdminSession as withSession,
} from "./adminTransport.effect"
import {
  AdminAvatarBadRequest,
  AdminAvatarNotFound,
  AdminAvatarServiceUnavailable,
  AdminGrantInvitesBadRequest,
  AdminInvalidCountBadRequest,
  AdminInvalidSessionBadRequest,
  AdminInvalidUserBadRequest,
  AdminInternalServerError,
  AdminLoginBadRequest,
  AdminLoginForbidden,
  AdminLoginTooManyRequests,
  AdminLoginUnauthorized,
  AdminNotFound,
  AdminSendEmailCodeBadRequest,
  AdminSendEmailCodeForbidden,
  AdminSendEmailCodeInternal,
  AdminSetPasswordBadRequest,
  AdminSetPasswordForbidden,
  AdminStepUpBadRequest,
  AdminStepUpForbidden,
  AdminStepUpUnauthorized,
  AdminTotpSetupBadRequest,
  AdminTotpSetupForbidden,
  AdminTotpVerifyBadRequest,
  AdminTotpVerifyForbidden,
  AdminTransportBadRequest,
  AdminUpdateUserBadRequest,
  AdminValidationError,
  AdminVerifyEmailCodeBadRequest,
  AdminVerifyEmailCodeForbidden,
  AdminVerifyEmailCodeInternal,
  AdminVerifyEmailCodeUnauthorized,
} from "./adminErrors.effect"
import {
  AdminActiveUsersQuery,
  AdminActiveUsersResult,
  AdminAppMetricsResult,
  AdminAvatarBody,
  AdminInviteCodesResult,
  AdminInviteCountInput,
  AdminInvitesQuery,
  AdminInvitesResult,
  AdminLoginInput,
  AdminMeResult,
  AdminOverviewMetricsResult,
  AdminRevokeSessionParams,
  AdminRevokeSessionResult,
  AdminSearchQuery,
  AdminSendEmailCodeInput,
  AdminSendEmailCodeResult,
  AdminSessionIdParam,
  AdminSetPasswordInput,
  AdminSpacesResult,
  AdminStepUpInput,
  AdminStepUpResult,
  AdminSuccess,
  AdminTechnicalMetricsResult,
  AdminTotpCodeInput,
  AdminTotpSetupResult,
  AdminUpdateUserInput,
  AdminUserDetailResult,
  AdminUserIdParam,
  AdminUserIdParams,
  AdminUsersResult,
  AdminVerifyEmailCodeInput,
  AdminVerifyEmailCodeResult,
  AdminWaitlistResult,
} from "./adminSchemas.effect"

const adminCookieResponseDocs = (
  description: string,
) =>
  OpenApi.annotations({
    transform: (operation) => {
      const response = operation["responses"]?.["200"]
      if (response !== undefined) {
        response.headers = {
          ...response.headers,
          "Set-Cookie": {
            description,
            schema: {
              type: "string",
            },
          },
        }
      }
      return operation
    },
  })

const publicEndpoint = <
  E,
>(
  endpoint: E,
): HttpApiEndpoint.AddMiddleware<
  E,
  AdminOriginGuard
> =>
  (
    endpoint as unknown as HttpApiEndpoint.Top
  ).middleware(AdminOriginGuard) as unknown as HttpApiEndpoint.AddMiddleware<
    E,
    AdminOriginGuard
  >

const authenticatedEndpoint = <
  E,
>(
  endpoint: E,
): HttpApiEndpoint.AddMiddleware<
  HttpApiEndpoint.AddMiddleware<
    E,
    AdminAuthentication
  >,
  AdminOriginGuard
> =>
  (
    endpoint as unknown as HttpApiEndpoint.Top
  )
    .middleware(AdminAuthentication)
    .middleware(AdminOriginGuard) as unknown as HttpApiEndpoint.AddMiddleware<
      HttpApiEndpoint.AddMiddleware<
        E,
        AdminAuthentication
      >,
      AdminOriginGuard
    >

const setupEndpoint = <
  E,
>(
  endpoint: E,
): HttpApiEndpoint.AddMiddleware<
  HttpApiEndpoint.AddMiddleware<
    HttpApiEndpoint.AddMiddleware<
      E,
      AdminSetupComplete
    >,
    AdminAuthentication
  >,
  AdminOriginGuard
> =>
  (
    endpoint as unknown as HttpApiEndpoint.Top
  )
    .middleware(AdminSetupComplete)
    .middleware(AdminAuthentication)
    .middleware(AdminOriginGuard) as unknown as HttpApiEndpoint.AddMiddleware<
      HttpApiEndpoint.AddMiddleware<
        HttpApiEndpoint.AddMiddleware<
          E,
          AdminSetupComplete
        >,
        AdminAuthentication
      >,
      AdminOriginGuard
    >

const stepUpEndpoint = <
  E,
>(
  endpoint: E,
): HttpApiEndpoint.AddMiddleware<
  HttpApiEndpoint.AddMiddleware<
    HttpApiEndpoint.AddMiddleware<
      HttpApiEndpoint.AddMiddleware<
        E,
        AdminRecentStepUp
      >,
      AdminSetupComplete
    >,
    AdminAuthentication
  >,
  AdminOriginGuard
> =>
  (
    endpoint as unknown as HttpApiEndpoint.Top
  )
    .middleware(AdminRecentStepUp)
    .middleware(AdminSetupComplete)
    .middleware(AdminAuthentication)
    .middleware(AdminOriginGuard) as unknown as HttpApiEndpoint.AddMiddleware<
      HttpApiEndpoint.AddMiddleware<
        HttpApiEndpoint.AddMiddleware<
          HttpApiEndpoint.AddMiddleware<
            E,
            AdminRecentStepUp
          >,
          AdminSetupComplete
        >,
        AdminAuthentication
      >,
      AdminOriginGuard
    >

const avatarEndpoint = <
  E,
>(
  endpoint: E,
): HttpApiEndpoint.AddMiddleware<
  HttpApiEndpoint.AddMiddleware<
    HttpApiEndpoint.AddMiddleware<
      E,
      AdminAvatarSetupComplete
    >,
    AdminAvatarAuthentication
  >,
  AdminAvatarOriginGuard
> =>
  (
    endpoint as unknown as HttpApiEndpoint.Top
  )
    .middleware(AdminAvatarSetupComplete)
    .middleware(AdminAvatarAuthentication)
    .middleware(AdminAvatarOriginGuard) as unknown as HttpApiEndpoint.AddMiddleware<
      HttpApiEndpoint.AddMiddleware<
        HttpApiEndpoint.AddMiddleware<
          E,
          AdminAvatarSetupComplete
        >,
        AdminAvatarAuthentication
      >,
      AdminAvatarOriginGuard
    >

const sendEmailCodeEndpoint = publicEndpoint(
  HttpApiEndpoint.post(
    "adminSendEmailCode",
    "/admin/auth/send-email-code",
    {
      payload: AdminSendEmailCodeInput,
      success: AdminSendEmailCodeResult,
      error: [
        AdminTransportBadRequest,
        AdminValidationError,
        AdminSendEmailCodeBadRequest,
        AdminSendEmailCodeForbidden,
        AdminSendEmailCodeInternal,
      ],
    },
  ),
)

const verifyEmailCodeEndpoint = publicEndpoint(
  HttpApiEndpoint.post(
    "adminVerifyEmailCode",
    "/admin/auth/verify-email-code",
    {
      payload: AdminVerifyEmailCodeInput,
      success: AdminVerifyEmailCodeResult,
      error: [
        AdminTransportBadRequest,
        AdminValidationError,
        AdminVerifyEmailCodeBadRequest,
        AdminVerifyEmailCodeUnauthorized,
        AdminVerifyEmailCodeForbidden,
        AdminVerifyEmailCodeInternal,
      ],
    },
  ).annotateMerge(
    adminCookieResponseDocs(
      "Creates the HttpOnly, SameSite=Strict admin session cookie.",
    ),
  ),
)

const loginEndpoint = publicEndpoint(
  HttpApiEndpoint.post(
    "adminLogin",
    "/admin/auth/login",
    {
      payload: AdminLoginInput,
      success: AdminSuccess,
      error: [
        AdminTransportBadRequest,
        AdminValidationError,
        AdminLoginBadRequest,
        AdminLoginUnauthorized,
        AdminLoginForbidden,
        AdminLoginTooManyRequests,
        AdminInternalServerError,
      ],
    },
  ).annotateMerge(
    adminCookieResponseDocs(
      "Creates the HttpOnly, SameSite=Strict admin session cookie.",
    ),
  ),
)

const setPasswordEndpoint = authenticatedEndpoint(
  HttpApiEndpoint.post(
    "adminSetPassword",
    "/admin/auth/set-password",
    {
      payload: AdminSetPasswordInput,
      success: AdminSuccess,
      error: [
        AdminTransportBadRequest,
        AdminValidationError,
        AdminSetPasswordBadRequest,
        AdminSetPasswordForbidden,
      ],
    },
  ),
)

const setupTotpEndpoint = authenticatedEndpoint(
  HttpApiEndpoint.get(
    "adminSetupTotp",
    "/admin/auth/totp/setup",
    {
      success: AdminTotpSetupResult,
      error: [
        AdminTotpSetupBadRequest,
        AdminTotpSetupForbidden,
      ],
    },
  ),
)

const verifyTotpEndpoint = authenticatedEndpoint(
  HttpApiEndpoint.post(
    "adminVerifyTotp",
    "/admin/auth/totp/verify",
    {
      payload: AdminTotpCodeInput,
      success: AdminSuccess,
      error: [
        AdminTransportBadRequest,
        AdminValidationError,
        AdminTotpVerifyBadRequest,
        AdminTotpVerifyForbidden,
      ],
    },
  ),
)

const stepUpAuthEndpoint = authenticatedEndpoint(
  HttpApiEndpoint.post(
    "adminStepUp",
    "/admin/auth/step-up",
    {
      payload: AdminStepUpInput,
      success: AdminStepUpResult,
      error: [
        AdminTransportBadRequest,
        AdminValidationError,
        AdminStepUpBadRequest,
        AdminStepUpUnauthorized,
        AdminStepUpForbidden,
      ],
    },
  ),
)

const logoutEndpoint = authenticatedEndpoint(
  HttpApiEndpoint.post(
    "adminLogout",
    "/admin/auth/logout",
    {
      success: AdminSuccess,
    },
  ).annotateMerge(
    adminCookieResponseDocs(
      "Clears the admin session cookie with Max-Age=0.",
    ),
  ),
)

const meEndpoint = authenticatedEndpoint(
  HttpApiEndpoint.get("adminMe", "/admin/me", {
    success: AdminMeResult,
  }),
)

const technicalMetricsEndpoint = setupEndpoint(
  HttpApiEndpoint.get(
    "adminTechnicalMetrics",
    "/admin/metrics/technical",
    {
      success: AdminTechnicalMetricsResult,
    },
  ),
)

const appMetricsEndpoint = setupEndpoint(
  HttpApiEndpoint.get(
    "adminAppMetrics",
    "/admin/metrics/app",
    {
      success: AdminAppMetricsResult,
    },
  ),
)

const overviewMetricsEndpoint = setupEndpoint(
  HttpApiEndpoint.get(
    "adminOverviewMetrics",
    "/admin/metrics/overview",
    {
      success: AdminOverviewMetricsResult,
    },
  ),
)

const activeUsersEndpoint = setupEndpoint(
  HttpApiEndpoint.get(
    "adminActiveUsers",
    "/admin/metrics/active-users",
    {
      payload: AdminActiveUsersQuery.fields,
      success: AdminActiveUsersResult,
      error: AdminValidationError,
    },
  ),
)

const waitlistEndpoint = setupEndpoint(
  HttpApiEndpoint.get(
    "adminWaitlist",
    "/admin/waitlist",
    {
      payload: AdminSearchQuery.fields,
      success: AdminWaitlistResult,
      error: AdminValidationError,
    },
  ),
)

const spacesEndpoint = setupEndpoint(
  HttpApiEndpoint.get(
    "adminSpaces",
    "/admin/spaces",
    {
      payload: AdminSearchQuery.fields,
      success: AdminSpacesResult,
      error: AdminValidationError,
    },
  ),
)

const usersEndpoint = setupEndpoint(
  HttpApiEndpoint.get(
    "adminUsers",
    "/admin/users",
    {
      payload: AdminSearchQuery.fields,
      success: AdminUsersResult,
      error: AdminValidationError,
    },
  ),
)

const userAvatarEndpoint = avatarEndpoint(
  HttpApiEndpoint.get(
    "adminUserAvatar",
    "/admin/users/:id/avatar",
    {
      params: AdminUserIdParams.fields,
      success: AdminAvatarBody,
      error: [
        AdminAvatarBadRequest,
        AdminAvatarNotFound,
        AdminAvatarServiceUnavailable,
      ],
    },
  ),
)

const userDetailEndpoint = setupEndpoint(
  HttpApiEndpoint.get(
    "adminUserDetail",
    "/admin/users/:id",
    {
      params: AdminUserIdParams.fields,
      success: AdminUserDetailResult,
      error: [
        AdminInvalidUserBadRequest,
        AdminNotFound,
      ],
    },
  ),
)

const invitesEndpoint = setupEndpoint(
  HttpApiEndpoint.get(
    "adminInvites",
    "/admin/invites",
    {
      payload: AdminInvitesQuery.fields,
      success: AdminInvitesResult,
      error: AdminValidationError,
    },
  ),
)

const generateInvitesEndpoint = stepUpEndpoint(
  HttpApiEndpoint.post(
    "adminGenerateInvites",
    "/admin/invites/generate",
    {
      payload: AdminInviteCountInput,
      success: AdminInviteCodesResult,
      error: [
        AdminTransportBadRequest,
        AdminValidationError,
        AdminInvalidCountBadRequest,
      ],
    },
  ),
)

const grantInvitesEndpoint = stepUpEndpoint(
  HttpApiEndpoint.post(
    "adminGrantInvites",
    "/admin/users/:id/invites",
    {
      params: AdminUserIdParams.fields,
      payload: AdminInviteCountInput,
      success: AdminInviteCodesResult,
      error: [
        AdminTransportBadRequest,
        AdminValidationError,
        AdminGrantInvitesBadRequest,
        AdminNotFound,
      ],
    },
  ),
)

const revokeSessionEndpoint = stepUpEndpoint(
  HttpApiEndpoint.post(
    "adminRevokeSession",
    "/admin/users/:id/sessions/:sessionId/revoke",
    {
      params: AdminRevokeSessionParams.fields,
      success: AdminRevokeSessionResult,
      error: [
        AdminInvalidSessionBadRequest,
        AdminNotFound,
      ],
    },
  ),
)

const updateUserEndpoint = stepUpEndpoint(
  HttpApiEndpoint.post(
    "adminUpdateUser",
    "/admin/users/:id/update",
    {
      params: AdminUserIdParams.fields,
      payload: AdminUpdateUserInput,
      success: AdminSuccess,
      error: [
        AdminTransportBadRequest,
        AdminValidationError,
        AdminUpdateUserBadRequest,
        AdminNotFound,
      ],
    },
  ),
)

export const AdminApiGroup = HttpApiGroup.make(
  "admin",
).add(
  sendEmailCodeEndpoint,
  verifyEmailCodeEndpoint,
  loginEndpoint,
  setPasswordEndpoint,
  setupTotpEndpoint,
  verifyTotpEndpoint,
  stepUpAuthEndpoint,
  logoutEndpoint,
  meEndpoint,
  technicalMetricsEndpoint,
  appMetricsEndpoint,
  overviewMetricsEndpoint,
  activeUsersEndpoint,
  waitlistEndpoint,
  spacesEndpoint,
  usersEndpoint,
  userAvatarEndpoint,
  userDetailEndpoint,
  invitesEndpoint,
  generateInvitesEndpoint,
  grantInvitesEndpoint,
  revokeSessionEndpoint,
  updateUserEndpoint,
)

export const makeAdminRouteGroup = () => {
  const api = makePlatformApiBase(
    "https://api.inline.chat",
  ).add(AdminApiGroup)
  const handlers = HttpApiBuilder.group(
    api,
    "admin",
    (groupHandlers) =>
      Effect.gen(function* () {
        const services = yield* Effect.context<
          | AdminOperations
          | ErrorReporter
        >()
        const operations = yield* AdminOperations
        const run = <
          E,
          R,
        >(
          effect: Effect.Effect<
            HttpServerResponse.HttpServerResponse,
            E,
            R
          >,
        ) => Effect.provide(effect, services)

        return groupHandlers
          .handleRaw(
            "adminSendEmailCode",
            ({ request }) =>
              run(
                complete(
                  "admin.auth.send-email-code",
                  AdminSendEmailCodeResult,
                  decodeBody(
                    request,
                    AdminSendEmailCodeInput,
                  ).pipe(
                    Effect.flatMap(({ input, info }) =>
                      operations.sendEmailCode(
                        input,
                        info,
                      ),
                    ),
                  ),
                ),
              ),
          )
          .handleRaw(
            "adminVerifyEmailCode",
            ({ request }) =>
              run(
                complete(
                  "admin.auth.verify-email-code",
                  AdminVerifyEmailCodeResult,
                  decodeBody(
                    request,
                    AdminVerifyEmailCodeInput,
                  ).pipe(
                    Effect.flatMap(({ input, info }) =>
                      operations.verifyEmailCode(
                        input,
                        info,
                      ),
                    ),
                  ),
                ),
              ),
          )
          .handleRaw(
            "adminLogin",
            ({ request }) =>
              run(
                complete(
                  "admin.auth.login",
                  AdminSuccess,
                  decodeBody(
                    request,
                    AdminLoginInput,
                  ).pipe(
                    Effect.flatMap(({ input, info }) =>
                      operations.login(input, info),
                    ),
                  ),
                ),
              ),
          )
          .handleRaw(
            "adminSetPassword",
            ({ request }) =>
              run(
                complete(
                  "admin.auth.set-password",
                  AdminSuccess,
                  decodeBody(
                    request,
                    AdminSetPasswordInput,
                  ).pipe(
                    Effect.flatMap(({ input, info }) =>
                      withSession((session) =>
                        operations.setPassword(
                          input,
                          session,
                          info,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          )
          .handleRaw(
            "adminSetupTotp",
            () =>
              run(
                complete(
                  "admin.auth.totp.setup",
                  AdminTotpSetupResult,
                  withSession((session) =>
                    operations.setupTotp(session),
                  ),
                ),
              ),
          )
          .handleRaw(
            "adminVerifyTotp",
            ({ request }) =>
              run(
                complete(
                  "admin.auth.totp.verify",
                  AdminSuccess,
                  decodeBody(
                    request,
                    AdminTotpCodeInput,
                  ).pipe(
                    Effect.flatMap(({ input, info }) =>
                      withSession((session) =>
                        operations.verifyTotp(
                          input,
                          session,
                          info,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          )
          .handleRaw(
            "adminStepUp",
            ({ request }) =>
              run(
                complete(
                  "admin.auth.step-up",
                  AdminStepUpResult,
                  decodeBody(
                    request,
                    AdminStepUpInput,
                  ).pipe(
                    Effect.flatMap(({ input }) =>
                      withSession((session) =>
                        operations.stepUp(
                          input,
                          session,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          )
          .handleRaw(
            "adminLogout",
            () =>
              run(
                complete(
                  "admin.auth.logout",
                  AdminSuccess,
                  withSession((session) =>
                    operations.logout(session),
                  ),
                ),
              ),
          )
          .handleRaw(
            "adminMe",
            () =>
              run(
                complete(
                  "admin.me",
                  AdminMeResult,
                  withSession((session) =>
                    operations.me(session),
                  ),
                ),
              ),
          )
          .handleRaw(
            "adminTechnicalMetrics",
            () =>
              run(
                complete(
                  "admin.metrics.technical",
                  AdminTechnicalMetricsResult,
                  withSession((session) =>
                    operations.technicalMetrics(session),
                  ),
                ),
              ),
          )
          .handleRaw(
            "adminAppMetrics",
            () =>
              run(
                complete(
                  "admin.metrics.app",
                  AdminAppMetricsResult,
                  withSession((session) =>
                    operations.appMetrics(session),
                  ),
                ),
              ),
          )
          .handleRaw(
            "adminOverviewMetrics",
            ({ request }) =>
              run(
                complete(
                  "admin.metrics.overview",
                  AdminOverviewMetricsResult,
                  infoOnly(request).pipe(
                    Effect.flatMap((info) =>
                      withSession((session) =>
                        operations.overviewMetrics(
                          session,
                          info,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          )
          .handleRaw(
            "adminActiveUsers",
            ({ request }) =>
              run(
                complete(
                  "admin.metrics.active-users",
                  AdminActiveUsersResult,
                  decodeQuery(
                    request,
                    AdminActiveUsersQuery,
                  ).pipe(
                    Effect.flatMap(({ input }) =>
                      withSession((session) =>
                        operations.activeUsers(
                          input,
                          session,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          )
          .handleRaw(
            "adminWaitlist",
            ({ request }) =>
              run(
                complete(
                  "admin.waitlist",
                  AdminWaitlistResult,
                  decodeQuery(
                    request,
                    AdminSearchQuery,
                  ).pipe(
                    Effect.flatMap(({ input }) =>
                      withSession((session) =>
                        operations.waitlist(
                          input,
                          session,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          )
          .handleRaw(
            "adminSpaces",
            ({ request }) =>
              run(
                complete(
                  "admin.spaces",
                  AdminSpacesResult,
                  decodeQuery(
                    request,
                    AdminSearchQuery,
                  ).pipe(
                    Effect.flatMap(({ input }) =>
                      withSession((session) =>
                        operations.spaces(
                          input,
                          session,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          )
          .handleRaw(
            "adminUsers",
            ({ request }) =>
              run(
                complete(
                  "admin.users",
                  AdminUsersResult,
                  decodeQuery(
                    request,
                    AdminSearchQuery,
                  ).pipe(
                    Effect.flatMap(({ input, info }) =>
                      withSession((session) =>
                        operations.users(
                          input,
                          session,
                          info,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          )
          .handleRaw(
            "adminUserAvatar",
            ({ request }) =>
              run(
                complete(
                  "admin.users.avatar",
                  undefined,
                  withSession((session) =>
                    decodePathParam(
                      request,
                      2,
                      AdminUserIdParam,
                      {
                        status: 400,
                        error: "invalid_user",
                        empty: true,
                      },
                    ).pipe(
                      Effect.flatMap((userId) =>
                        operations.avatar(
                          userId,
                          session,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          )
          .handleRaw(
            "adminUserDetail",
            ({ request }) =>
              run(
                complete(
                  "admin.users.detail",
                  AdminUserDetailResult,
                  infoOnly(request).pipe(
                    Effect.flatMap((info) =>
                      withSession((session) =>
                        decodePathParam(
                          request,
                          2,
                          AdminUserIdParam,
                          {
                            status: 400,
                            error: "invalid_user",
                          },
                        ).pipe(
                          Effect.flatMap((userId) =>
                            operations.userDetail(
                              userId,
                              session,
                              info,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          )
          .handleRaw(
            "adminInvites",
            ({ request }) =>
              run(
                complete(
                  "admin.invites",
                  AdminInvitesResult,
                  decodeQuery(
                    request,
                    AdminInvitesQuery,
                  ).pipe(
                    Effect.flatMap(({ input }) =>
                      withSession((session) =>
                        operations.invites(
                          input,
                          session,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          )
          .handleRaw(
            "adminGenerateInvites",
            ({ request }) =>
              run(
                complete(
                  "admin.invites.generate",
                  AdminInviteCodesResult,
                  decodeBody(
                    request,
                    AdminInviteCountInput,
                  ).pipe(
                    Effect.flatMap(({ input, info }) =>
                      withSession((session) =>
                        operations.generateInvites(
                          input,
                          session,
                          info,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          )
          .handleRaw(
            "adminGrantInvites",
            ({ request }) =>
              run(
                complete(
                  "admin.invites.grant",
                  AdminInviteCodesResult,
                  decodeBody(
                    request,
                    AdminInviteCountInput,
                  ).pipe(
                    Effect.flatMap(({ input, info }) =>
                      withSession((session) =>
                        decodePathParam(
                          request,
                          2,
                          AdminUserIdParam,
                          {
                            status: 400,
                            error: "invalid_user",
                          },
                        ).pipe(
                          Effect.flatMap((userId) =>
                            operations.grantInvites(
                              userId,
                              input,
                              session,
                              info,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          )
          .handleRaw(
            "adminRevokeSession",
            ({ request }) =>
              run(
                complete(
                  "admin.users.sessions.revoke",
                  AdminRevokeSessionResult,
                  infoOnly(request).pipe(
                    Effect.flatMap((info) =>
                      withSession((session) =>
                        Effect.all([
                          decodePathParam(
                            request,
                            2,
                            AdminUserIdParam,
                            {
                              status: 400,
                              error: "invalid_session",
                            },
                          ),
                          decodePathParam(
                            request,
                            4,
                            AdminSessionIdParam,
                            {
                              status: 400,
                              error: "invalid_session",
                            },
                          ),
                        ]).pipe(
                          Effect.flatMap(
                            ([userId, sessionId]) =>
                              operations.revokeSession(
                                userId,
                                sessionId,
                                session,
                                info,
                              ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          )
          .handleRaw(
            "adminUpdateUser",
            ({ request }) =>
              run(
                complete(
                  "admin.users.update",
                  AdminSuccess,
                  decodeBody(
                    request,
                    AdminUpdateUserInput,
                  ).pipe(
                    Effect.flatMap(({ input, info }) =>
                      withSession((session) =>
                        decodePathParam(
                          request,
                          2,
                          AdminUserIdParam,
                          {
                            status: 400,
                            error: "invalid_user",
                          },
                        ).pipe(
                          Effect.flatMap((userId) =>
                            operations.updateUser(
                              userId,
                              input,
                              session,
                              info,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          )
      }),
  )

  return defineHttpRouteGroup({
    apiId: PLATFORM_API_ID,
    document: "platform",
    group: AdminApiGroup,
    handlers,
  })
}

export const AdminRouteGroup = makeAdminRouteGroup()
