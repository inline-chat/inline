import {
  Effect,
  Layer,
} from "effect"
import {
  handleAuthorizationServerMetadata,
  handleAuthorizeConsent,
  handleAuthorizeSendEmailCode,
  handleAuthorizeSendSmsCode,
  handleAuthorizeVerifyEmailCode,
  handleAuthorizeVerifySmsCode,
  handleIntrospect,
  handleRegister,
  handleRevoke,
  handleToken,
  prepareAuthorizeRequest,
} from "./httpHandlers"
import {
  OAuthHttpService,
} from "./httpService.effect"
import {
  makeOAuthHttpService,
} from "./httpServiceAdapter.effect"
import {
  OAuthRateLimiter,
  makeOAuthRateLimiterLayer,
} from "./rateLimiter.effect"

export const OAuthHttpServiceLive = Layer.effect(
  OAuthHttpService,
  OAuthRateLimiter.use((rateLimiter) =>
    Effect.succeed(
      makeOAuthHttpService({
        metadata: handleAuthorizationServerMetadata,
        register: (request, body, clientIp) =>
          handleRegister(
            request,
            body,
            clientIp,
            rateLimiter,
          ),
        authorize: prepareAuthorizeRequest,
        sendEmailCode: (request, body, clientIp) =>
          handleAuthorizeSendEmailCode(
            request,
            body,
            clientIp,
            rateLimiter,
          ),
        verifyEmailCode: (request, body, clientIp) =>
          handleAuthorizeVerifyEmailCode(
            request,
            body,
            clientIp,
            rateLimiter,
          ),
        sendSmsCode: (request, body, clientIp) =>
          handleAuthorizeSendSmsCode(
            request,
            body,
            clientIp,
            rateLimiter,
          ),
        verifySmsCode: (request, body, clientIp) =>
          handleAuthorizeVerifySmsCode(
            request,
            body,
            clientIp,
            rateLimiter,
          ),
        consent: handleAuthorizeConsent,
        token: (request, body, clientIp) =>
          handleToken(
            request,
            body,
            clientIp,
            rateLimiter,
          ),
        revoke: handleRevoke,
        introspect: handleIntrospect,
      }),
    ),
  ),
).pipe(
  Layer.provide(makeOAuthRateLimiterLayer()),
)
