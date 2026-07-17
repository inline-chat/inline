import { Elysia } from "elysia"
import {
  handleAuthorizationServerMetadata,
  handleAuthorizeConsent,
  handleAuthorizeSendEmailCode,
  handleAuthorizeVerifyEmailCode,
  handleIntrospect,
  handleRegister,
  handleRevoke,
  handleToken,
  prepareAuthorizeRequest,
} from "@in/server/modules/oauth/httpHandlers"
import { OAuthHandlerFailure } from "@in/server/modules/oauth/httpHandlerFailure"
import { Log } from "@in/server/utils/log"

const executeLegacyOAuth = async (
  run: () => Response | Promise<Response>,
): Promise<Response> => {
  try {
    return await run()
  } catch (cause) {
    if (cause instanceof OAuthHandlerFailure) {
      Log.shared.error(cause.message, cause.cause)
      return cause.response
    }
    throw cause
  }
}

const legacyOAuthClientIp = (
  request: Request,
): string | undefined => {
  const cfConnectingIp =
    request.headers.get("cf-connecting-ip")?.trim()
  if (cfConnectingIp) return cfConnectingIp

  const realIp = request.headers.get("x-real-ip")?.trim()
  if (realIp) return realIp

  const forwarded = request.headers.get("x-forwarded-for")
  const first = forwarded?.split(",", 1)[0]?.trim()
  return first || undefined
}

export const oauth = new Elysia({ name: "oauth" })
  .get("/.well-known/oauth-authorization-server", () =>
    executeLegacyOAuth(() =>
      handleAuthorizationServerMetadata(),
    ),
  )
  .post("/oauth/register", ({ request, body }) =>
    executeLegacyOAuth(() =>
      handleRegister(
        request,
        body,
        legacyOAuthClientIp(request),
      ),
    ),
  )
  .post("/register", ({ request, body }) =>
    executeLegacyOAuth(() =>
      handleRegister(
        request,
        body,
        legacyOAuthClientIp(request),
      ),
    ),
  )
  .get("/oauth/authorize", ({ request }) =>
    executeLegacyOAuth(() =>
      prepareAuthorizeRequest(request),
    ),
  )
  .get("/authorize", ({ request }) =>
    executeLegacyOAuth(() =>
      prepareAuthorizeRequest(request),
    ),
  )
  .post("/oauth/authorize/send-email-code", ({ request, body }) =>
    executeLegacyOAuth(() =>
      handleAuthorizeSendEmailCode(
        request,
        body,
        legacyOAuthClientIp(request),
      ),
    ),
  )
  .post("/oauth/authorize/verify-email-code", ({ request, body }) =>
    executeLegacyOAuth(() =>
      handleAuthorizeVerifyEmailCode(
        request,
        body,
        legacyOAuthClientIp(request),
      ),
    ),
  )
  .post("/oauth/authorize/consent", ({ request, body }) =>
    executeLegacyOAuth(() =>
      handleAuthorizeConsent(request, body),
    ),
  )
  .post("/oauth/token", ({ request, body }) =>
    executeLegacyOAuth(() =>
      handleToken(
        request,
        body,
        legacyOAuthClientIp(request),
      ),
    ),
  )
  .post("/token", ({ request, body }) =>
    executeLegacyOAuth(() =>
      handleToken(
        request,
        body,
        legacyOAuthClientIp(request),
      ),
    ),
  )
  .post("/oauth/revoke", ({ body }) =>
    executeLegacyOAuth(() => handleRevoke(body)),
  )
  .post("/revoke", ({ body }) =>
    executeLegacyOAuth(() => handleRevoke(body)),
  )
  .post("/oauth/introspect", ({ request, body }) =>
    executeLegacyOAuth(() =>
      handleIntrospect(request, body),
    ),
  )
