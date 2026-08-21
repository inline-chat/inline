import {
  Effect,
  Layer,
} from "effect"
import {
  handleAuthorizationServerMetadata,
  handleAuthorizeConsent,
  handleAuthorizeContinue,
  handleAuthorizeSendEmailCode,
  handleAuthorizeSendSmsCode,
  handleAuthorizeVerifyEmailCode,
  handleAuthorizeVerifySmsCode,
  handleIntrospect,
  handleRegister,
  handleRevoke,
  handleToken,
  handleProviderCallback,
  handleProviderContinueInvite,
  handleProviderRedeem,
  handleProviderSendEmailCode,
  handleProviderStart,
  handleProviderVerifyEmailCode,
  prepareAuthorizeRequest,
} from "./httpHandlers"
import {
  handleHostedLoginGet,
  handleHostedLoginSendEmail,
  handleHostedLoginSendSms,
  handleHostedLoginVerifyEmail,
  handleHostedLoginVerifySms,
} from "@in/server/modules/auth/hostedLogin/httpHandlers"
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
        authorizeContinue: handleAuthorizeContinue,
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
        providerStart: (request, clientIp) =>
          handleProviderStart(request, clientIp, rateLimiter),
        providerCallbackGoogle: (request) => handleProviderCallback("google", request),
        providerCallbackApple: (request, body) => handleProviderCallback("apple", request, body),
        providerContinueInvite: handleProviderContinueInvite,
        providerSendEmailCode: (body, clientIp) =>
          handleProviderSendEmailCode(body, clientIp, rateLimiter),
        providerVerifyEmailCode: handleProviderVerifyEmailCode,
        providerRedeem: handleProviderRedeem,
        hostedLoginGet: handleHostedLoginGet,
        hostedLoginSendEmail: handleHostedLoginSendEmail,
        hostedLoginVerifyEmail: handleHostedLoginVerifyEmail,
        hostedLoginSendSms: handleHostedLoginSendSms,
        hostedLoginVerifySms: handleHostedLoginVerifySms,
      }),
    ),
  ),
).pipe(
  Layer.provide(makeOAuthRateLimiterLayer()),
)
