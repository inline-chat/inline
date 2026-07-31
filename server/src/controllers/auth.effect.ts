import { Effect } from "effect"
import {
  HttpApiBuilder,
  HttpApiGroup,
} from "effect/unstable/httpapi"
import {
  ErrorReporter,
} from "../core/errors/errorReporter"
import {
  makePlatformApiBase,
  PLATFORM_API_ID,
} from "../core/http/openApi"
import { defineHttpRouteGroup } from "../core/http/routeGroup"
import {
  IdentityOperations,
} from "../modules/auth/identityOperations.effect"
import {
  OAuthHttpService,
} from "../modules/oauth/httpService.effect"
import {
  executeIdentityLogout,
  executeUnauthenticatedIdentity,
  IdentityEndpoints,
} from "./identity.effect"
import {
  executeOAuth,
  OAuthEndpoints,
} from "./oauth.effect"
import {
  SessionAuthentication,
} from "./plugins.effect"

/**
 * Slice 2's single executable route group.
 *
 * The endpoint collections remain split by protocol in their source files,
 * while integration sees one stable auth group, handler service, and OpenAPI
 * contribution.
 */
export const AuthApiGroup = HttpApiGroup.make("auth").add(
  IdentityEndpoints.getSendSmsCode,
  IdentityEndpoints.postSendSmsCode,
  IdentityEndpoints.getVerifySmsCode,
  IdentityEndpoints.postVerifySmsCode,
  IdentityEndpoints.getSendEmailCode,
  IdentityEndpoints.postSendEmailCode,
  IdentityEndpoints.getVerifyEmailCode,
  IdentityEndpoints.postVerifyEmailCode,
  IdentityEndpoints.getCheckInviteCode,
  IdentityEndpoints.postCheckInviteCode,
  IdentityEndpoints.getLogout,
  IdentityEndpoints.getLogoutWithToken,
  IdentityEndpoints.postLogout,
  OAuthEndpoints.oauthMetadata,
  OAuthEndpoints.oauthRegister,
  OAuthEndpoints.oauthRegisterAlias,
  OAuthEndpoints.oauthAuthorize,
  OAuthEndpoints.oauthAuthorizeAlias,
  OAuthEndpoints.oauthSendEmailCode,
  OAuthEndpoints.oauthVerifyEmailCode,
  OAuthEndpoints.oauthSendSmsCode,
  OAuthEndpoints.oauthVerifySmsCode,
  OAuthEndpoints.oauthConsent,
  OAuthEndpoints.oauthToken,
  OAuthEndpoints.oauthTokenAlias,
  OAuthEndpoints.oauthRevoke,
  OAuthEndpoints.oauthRevokeAlias,
  OAuthEndpoints.oauthIntrospect,
)

export const makeAuthRouteGroup = () => {
  const api = makePlatformApiBase(
    "https://api.inline.chat",
  ).add(AuthApiGroup)
  const handlers = HttpApiBuilder.group(
    api,
    "auth",
    (groupHandlers) =>
      Effect.gen(function* () {
        const services = yield* Effect.context<
          | ErrorReporter
          | IdentityOperations
          | OAuthHttpService
          | SessionAuthentication
        >()
        const execute = <A, E, R>(
          effect: Effect.Effect<A, E, R>,
        ) => Effect.provide(effect, services)

        return groupHandlers
        .handleRaw("getSendSmsCode", ({ request }) =>
          execute(
            executeUnauthenticatedIdentity(
              "sendSmsCode",
              request,
            ),
          ),
        )
        .handleRaw("postSendSmsCode", ({ request }) =>
          execute(
            executeUnauthenticatedIdentity(
              "sendSmsCode",
              request,
            ),
          ),
        )
        .handleRaw("getVerifySmsCode", ({ request }) =>
          execute(
            executeUnauthenticatedIdentity(
              "verifySmsCode",
              request,
            ),
          ),
        )
        .handleRaw("postVerifySmsCode", ({ request }) =>
          execute(
            executeUnauthenticatedIdentity(
              "verifySmsCode",
              request,
            ),
          ),
        )
        .handleRaw("getSendEmailCode", ({ request }) =>
          execute(
            executeUnauthenticatedIdentity(
              "sendEmailCode",
              request,
            ),
          ),
        )
        .handleRaw("postSendEmailCode", ({ request }) =>
          execute(
            executeUnauthenticatedIdentity(
              "sendEmailCode",
              request,
            ),
          ),
        )
        .handleRaw("getVerifyEmailCode", ({ request }) =>
          execute(
            executeUnauthenticatedIdentity(
              "verifyEmailCode",
              request,
            ),
          ),
        )
        .handleRaw("postVerifyEmailCode", ({ request }) =>
          execute(
            executeUnauthenticatedIdentity(
              "verifyEmailCode",
              request,
            ),
          ),
        )
        .handleRaw("getCheckInviteCode", ({ request }) =>
          execute(
            executeUnauthenticatedIdentity(
              "checkInviteCode",
              request,
            ),
          ),
        )
        .handleRaw("postCheckInviteCode", ({ request }) =>
          execute(
            executeUnauthenticatedIdentity(
              "checkInviteCode",
              request,
            ),
          ),
        )
        .handleRaw("getLogout", ({ request }) =>
          execute(
            executeIdentityLogout(
              request,
              undefined,
            ),
          ),
        )
        .handleRaw(
          "getLogoutWithToken",
          ({ params, request }) =>
            execute(
              executeIdentityLogout(
                request,
                params.token ?? undefined,
              ),
            ),
        )
        .handleRaw("postLogout", ({ request }) =>
          execute(
            executeIdentityLogout(
              request,
              undefined,
            ),
          ),
        )
        .handleRaw("oauthMetadata", ({ request }) =>
          execute(
            executeOAuth(
              "metadata",
              request,
            ),
          ),
        )
        .handleRaw("oauthRegister", ({ request }) =>
          execute(
            executeOAuth(
              "register",
              request,
            ),
          ),
        )
        .handleRaw("oauthRegisterAlias", ({ request }) =>
          execute(
            executeOAuth(
              "register",
              request,
            ),
          ),
        )
        .handleRaw("oauthAuthorize", ({ request }) =>
          execute(
            executeOAuth(
              "authorize",
              request,
            ),
          ),
        )
        .handleRaw("oauthAuthorizeAlias", ({ request }) =>
          execute(
            executeOAuth(
              "authorize",
              request,
            ),
          ),
        )
        .handleRaw("oauthSendEmailCode", ({ request }) =>
          execute(
            executeOAuth(
              "sendEmailCode",
              request,
            ),
          ),
        )
        .handleRaw("oauthVerifyEmailCode", ({ request }) =>
          execute(
            executeOAuth(
              "verifyEmailCode",
              request,
            ),
          ),
        )
        .handleRaw("oauthSendSmsCode", ({ request }) =>
          execute(
            executeOAuth(
              "sendSmsCode",
              request,
            ),
          ),
        )
        .handleRaw("oauthVerifySmsCode", ({ request }) =>
          execute(
            executeOAuth(
              "verifySmsCode",
              request,
            ),
          ),
        )
        .handleRaw("oauthConsent", ({ request }) =>
          execute(
            executeOAuth(
              "consent",
              request,
            ),
          ),
        )
        .handleRaw("oauthToken", ({ request }) =>
          execute(
            executeOAuth(
              "token",
              request,
            ),
          ),
        )
        .handleRaw("oauthTokenAlias", ({ request }) =>
          execute(
            executeOAuth(
              "token",
              request,
            ),
          ),
        )
        .handleRaw("oauthRevoke", ({ request }) =>
          execute(
            executeOAuth(
              "revoke",
              request,
            ),
          ),
        )
        .handleRaw("oauthRevokeAlias", ({ request }) =>
          execute(
            executeOAuth(
              "revoke",
              request,
            ),
          ),
        )
        .handleRaw("oauthIntrospect", ({ request }) =>
          execute(
            executeOAuth(
              "introspect",
              request,
            ),
          ),
        )
      }),
  )

  return defineHttpRouteGroup({
    apiId: PLATFORM_API_ID,
    document: "platform",
    group: AuthApiGroup,
    handlers,
  })
}

export const AuthRouteGroup = makeAuthRouteGroup()
