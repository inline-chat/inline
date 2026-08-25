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
  handleNativeAppleComplete,
  handleNativeAppleContinueInvite,
  handleNativeAppleStart,
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
        providerNativeAppleStart: (body, clientIp) =>
          handleNativeAppleStart(body, clientIp, rateLimiter),
        providerNativeAppleComplete: (body, clientIp) =>
          handleNativeAppleComplete(body, clientIp, rateLimiter),
        providerNativeAppleContinueInvite: (body, clientIp) =>
          handleNativeAppleContinueInvite(body, clientIp, rateLimiter),
        providerCallbackGoogle: (request, clientIp) =>
          handleProviderCallback("google", request, undefined, clientIp, rateLimiter),
        providerCallbackApple: (request, body, clientIp) =>
          handleProviderCallback("apple", request, body, clientIp, rateLimiter),
        providerContinueInvite: (body, clientIp) =>
          handleProviderContinueInvite(body, clientIp, rateLimiter),
        providerSendEmailCode: (body, clientIp) =>
          handleProviderSendEmailCode(body, clientIp, rateLimiter),
        providerVerifyEmailCode: (body, clientIp) =>
          handleProviderVerifyEmailCode(body, clientIp, rateLimiter),
        providerRedeem: (body, clientIp) =>
          handleProviderRedeem(body, clientIp, rateLimiter),
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
