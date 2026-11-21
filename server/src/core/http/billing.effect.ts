import { Data, Effect, Layer } from "effect"
import { HttpRouter, HttpServerRequest, HttpServerResponse } from "effect/unstable/http"
import {
  BILLING_CANCEL_PATH,
  BILLING_MANAGED_PATH,
  BILLING_RETURN_PATH,
  BILLING_WEBHOOK_PATH,
  billingPage,
  handleBillingWebhook,
} from "../../modules/billing/http"
import { webResponseToHttpServerResponse } from "./webResponse"

class BillingTransportError extends Data.TaggedError("BillingTransportError") {}

const failed = HttpServerResponse.text('{"error":"internal_error"}', {
  status: 500,
  contentType: "application/json",
  headers: { "cache-control": "no-store" },
})

const webhook = Effect.gen(function* () {
  const request = yield* HttpServerRequest.HttpServerRequest
  const webRequest = yield* HttpServerRequest.toWeb(request).pipe(Effect.mapError(() => new BillingTransportError()))
  const response = yield* Effect.tryPromise({
    try: () => handleBillingWebhook(webRequest),
    catch: () => new BillingTransportError(),
  })
  return webResponseToHttpServerResponse(response)
}).pipe(Effect.catchTag("BillingTransportError", () => Effect.succeed(failed)))

const page = (kind: "return" | "cancel" | "managed") =>
  Effect.promise(() => Promise.resolve(webResponseToHttpServerResponse(billingPage(kind))))

/** Checkout service webhook and the browser pages Stripe sends buyers back to. */
export const BillingRoutesLive = Layer.effectDiscard(
  HttpRouter.HttpRouter.use((router) =>
    Effect.all([
      router.add("POST", BILLING_WEBHOOK_PATH, webhook),
      router.add("GET", BILLING_RETURN_PATH, page("return")),
      router.add("GET", BILLING_CANCEL_PATH, page("cancel")),
      router.add("GET", BILLING_MANAGED_PATH, page("managed")),
    ]),
  ),
)
