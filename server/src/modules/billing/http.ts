import { readBoundedBody } from "@in/server/realtime/httpRpc"
import { Log } from "@in/server/utils/log"
import { CheckoutServiceError } from "./checkoutClient"
import { applyNotification, checkoutConfig, parseNotification } from "./service"
import { verifyCheckoutSignature } from "./signature"

const log = new Log("billing.http")

export const BILLING_WEBHOOK_PATH = "/billing/checkout/events"
export const BILLING_RETURN_PATH = "/billing/return"
export const BILLING_CANCEL_PATH = "/billing/cancel"
export const BILLING_MANAGED_PATH = "/billing/managed"

const maxBodyBytes = 64 * 1024

const json = (value: unknown, status = 200) =>
  new Response(JSON.stringify(value), { status, headers: { "content-type": "application/json", "cache-control": "no-store" } })

/**
 * Receives signed notifications from the shared checkout service. Verifies the HMAC over
 * the raw body before parsing, and acknowledges only after the state change is committed,
 * so the service (and Stripe behind it) retries anything that failed.
 */
export const handleBillingWebhook = async (request: Request): Promise<Response> => {
  const config = checkoutConfig()
  if (!config) return json({ error: "billing_unconfigured" }, 503)

  const length = Number(request.headers.get("content-length") ?? "0")
  if (length > maxBodyBytes) return json({ error: "too_large" }, 413)
  // Chunked bodies carry no length; the bounded reader enforces the cap while streaming.
  const bytes = await readBoundedBody(request, maxBodyBytes)
  if (!bytes) return json({ error: "too_large" }, 413)
  const body = new TextDecoder().decode(bytes)

  if (!verifyCheckoutSignature(config.webhookSecret, request.headers.get("noor-checkout-signature"), body)) {
    return json({ error: "invalid_signature" }, 400)
  }
  const event = parseNotification(body)
  if (!event) return json({ error: "invalid_event" }, 400)

  try {
    const outcome = await applyNotification(config, event)
    log.info("billing notification", { event: event.id, type: event.type, outcome })
    return json({ received: true, outcome })
  } catch (error) {
    log.error("billing notification failed", {
      event: event.id,
      type: event.type,
      code: error instanceof CheckoutServiceError ? error.code : undefined,
      error,
    })
    return json({ error: "billing_notification_failed" }, 500)
  }
}

const escapeHtml = (value: string) =>
  value.replace(/[&<>"']/g, (char) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[char]!)

/**
 * The browser after checkout isn't signed in to Inline, so these pages show no purchase
 * details; the app refreshes its own billing state when it comes back to the front.
 */
export const billingPage = (kind: "return" | "cancel" | "managed"): Response => {
  const copy = {
    return: { title: "Thanks for upgrading", body: "Your payment is confirmed in a few seconds. Inline updates on its own." },
    cancel: { title: "Checkout canceled", body: "Nothing was charged. You can upgrade any time from Inline's settings." },
    managed: { title: "Billing updated", body: "Your changes are saved. Inline updates on its own." },
  }[kind]
  const html = `<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${escapeHtml(copy.title)} · Inline</title>
<body style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;max-width:480px;margin:96px auto;padding:0 24px;color:#171717;text-align:center">
<h1 style="font-size:24px;font-weight:600">${escapeHtml(copy.title)}</h1>
<p style="color:#525252;line-height:1.5">${escapeHtml(copy.body)}</p>
<p style="margin-top:32px"><a href="inline://billing" style="display:inline-block;padding:10px 20px;border-radius:10px;background:#171717;color:#fff;text-decoration:none">Open Inline</a></p>
</body></html>`
  return new Response(html, { headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store", "referrer-policy": "no-referrer" } })
}
