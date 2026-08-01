import {
  Context,
  Data,
  Effect,
  Schema,
} from "effect"
import {
  HttpServerRequest,
  HttpServerResponse,
} from "effect/unstable/http"
import {
  HttpApiEndpoint,
  HttpApiSchema,
} from "effect/unstable/httpapi"
import { hashUnsubscribeToken } from "@in/server/modules/emailCampaigns/contactCrypto"

const EmailUnsubscribeHtml = Schema.String.pipe(
  HttpApiSchema.asText({ contentType: "text/html; charset=utf-8" }),
).annotate({ identifier: "EmailUnsubscribeHtml" })

const TokenParams = Schema.Struct({ token: Schema.String })

export const EmailUnsubscribeEndpoints = {
  confirm: HttpApiEndpoint.get(
    "emailUnsubscribeConfirm",
    "/email/unsubscribe/:token",
    { params: TokenParams.fields, success: EmailUnsubscribeHtml },
  ),
  submit: HttpApiEndpoint.post(
    "emailUnsubscribeSubmit",
    "/email/unsubscribe/:token",
    { params: TokenParams.fields, success: EmailUnsubscribeHtml },
  ),
} as const

export class EmailUnsubscribeOperationFailure extends Data.TaggedError(
  "EmailUnsubscribeOperationFailure",
)<{ readonly cause: unknown }> {}

interface Contact {
  readonly emailKey: string
  readonly emailEncrypted: Buffer
}

export interface EmailUnsubscribeOperationsShape {
  readonly lookup: (tokenHash: string) => Effect.Effect<Contact | null, EmailUnsubscribeOperationFailure>
  readonly suppress: (contact: Contact) => Effect.Effect<void, EmailUnsubscribeOperationFailure>
}

export class EmailUnsubscribeOperations extends Context.Service<
  EmailUnsubscribeOperations,
  EmailUnsubscribeOperationsShape
>()("@inline/server/auxiliary/EmailUnsubscribeOperations") {}

const page = (content: string): HttpServerResponse.HttpServerResponse =>
  HttpServerResponse.raw(
    new TextEncoder().encode(`<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Email preferences · Inline</title><body style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;max-width:560px;margin:64px auto;padding:0 24px;color:#171717"><h1 style="font-size:24px">Inline email preferences</h1>${content}</body></html>`),
    { headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" } },
  )

const tokenFromRequest = (request: HttpServerRequest.HttpServerRequest): string => {
  const pathname = new URL(request.url, "https://api.inline.chat").pathname
  return decodeURIComponent(pathname.split("/").at(-1) ?? "")
}

const lookup = (request: HttpServerRequest.HttpServerRequest) =>
  EmailUnsubscribeOperations.use((operations) => {
    const token = tokenFromRequest(request)
    if (!/^[A-Za-z0-9_-]{40,64}$/.test(token)) return Effect.succeed(null)
    return operations.lookup(hashUnsubscribeToken(token))
  })

export const executeEmailUnsubscribeConfirm = (
  request: HttpServerRequest.HttpServerRequest,
) =>
  lookup(request).pipe(
    Effect.map((contact) =>
      contact
        ? page('<p>Stop receiving campaign emails from Inline?</p><form method="post"><button type="submit" style="border:0;border-radius:8px;background:#171717;color:white;padding:10px 16px;font-weight:600">Unsubscribe</button></form>')
        : page("<p>This unsubscribe link is invalid or expired.</p>"),
    ),
  )

export const executeEmailUnsubscribeSubmit = (
  request: HttpServerRequest.HttpServerRequest,
) =>
  Effect.gen(function* () {
    const contact = yield* lookup(request)
    if (contact) {
      const operations = yield* EmailUnsubscribeOperations
      yield* operations.suppress(contact)
    }
    return page("<p>You are unsubscribed from Inline campaign emails.</p>")
  })
