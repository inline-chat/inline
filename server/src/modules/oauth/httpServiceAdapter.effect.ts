import { Effect } from "effect"
import {
  LegacyElysiaJsonParseError,
  parseLegacyElysiaBody,
} from "../../core/http/legacyElysiaBody"
import {
  OAuthHttpFailure,
  type OAuthHttpInput,
  type OAuthHttpOperation,
  type OAuthHttpServiceShape,
} from "./httpService.effect"
import { OAuthHandlerFailure } from "./httpHandlerFailure"

export interface OAuthHttpHandlers {
  readonly metadata: () => Response
  readonly register: (
    request: Request,
    body: unknown,
    clientIp?: string,
  ) => Promise<Response>
  readonly authorize: (request: Request) => Promise<Response>
  readonly sendEmailCode: (
    request: Request,
    body: unknown,
    clientIp?: string,
  ) => Promise<Response>
  readonly verifyEmailCode: (
    request: Request,
    body: unknown,
    clientIp?: string,
  ) => Promise<Response>
  readonly consent: (
    request: Request,
    body: unknown,
  ) => Promise<Response>
  readonly token: (
    request: Request,
    body: unknown,
    clientIp?: string,
  ) => Promise<Response>
  readonly revoke: (body: unknown) => Promise<Response>
  readonly introspect: (
    request: Request,
    body: unknown,
  ) => Promise<Response>
}

const badRequest = (): Response =>
  new Response(
    new TextEncoder().encode("Bad Request"),
    {
      status: 400,
    },
  )

const execute = async (
  handlers: OAuthHttpHandlers,
  operation: OAuthHttpOperation,
  {
    request,
    clientIp,
  }: OAuthHttpInput,
): Promise<Response> => {
  if (operation === "metadata") {
    return handlers.metadata()
  }
  if (operation === "authorize") {
    return handlers.authorize(request)
  }

  let body: unknown
  try {
    body = await parseLegacyElysiaBody(request)
  } catch (cause) {
    if (cause instanceof LegacyElysiaJsonParseError) {
      return badRequest()
    }
    throw cause
  }

  switch (operation) {
    case "register":
      return handlers.register(request, body, clientIp)
    case "sendEmailCode":
      return handlers.sendEmailCode(request, body, clientIp)
    case "verifyEmailCode":
      return handlers.verifyEmailCode(
        request,
        body,
        clientIp,
      )
    case "consent":
      return handlers.consent(request, body)
    case "token":
      return handlers.token(request, body, clientIp)
    case "revoke":
      return handlers.revoke(body)
    case "introspect":
      return handlers.introspect(request, body)
  }
}

export const makeOAuthHttpService = (
  handlers: OAuthHttpHandlers,
): OAuthHttpServiceShape => ({
  execute: (operation, input) =>
    Effect.tryPromise({
      try: () => execute(handlers, operation, input),
      catch: (cause) =>
        new OAuthHttpFailure({
          operation,
          cause: cause instanceof OAuthHandlerFailure
            ? cause.cause
            : cause,
          publicResponse: cause instanceof OAuthHandlerFailure
            ? cause.response
            : undefined,
        }),
    }),
})
