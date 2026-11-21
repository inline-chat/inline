/** Thin client for the shared checkout service (see the checkout repo README). */

export interface CheckoutConfig {
  readonly baseUrl: string
  readonly appId: string
  readonly live: boolean
  readonly apiToken: string
  readonly webhookSecret: string
  /** Plan codes the service has configured for Inline; clients only see these. */
  readonly plans: readonly string[]
}

export const loadCheckoutConfig = (env: Record<string, string | undefined> = process.env): CheckoutConfig | null => {
  const {
    INLINE_CHECKOUT_BASE_URL: baseUrl,
    INLINE_CHECKOUT_APP_ID: appId,
    INLINE_CHECKOUT_MODE: mode,
    INLINE_CHECKOUT_API_TOKEN: apiToken,
    INLINE_CHECKOUT_WEBHOOK_SECRET: webhookSecret,
    INLINE_CHECKOUT_PLANS: plans,
  } = env
  if (!baseUrl || !appId || !apiToken || !webhookSecret) return null
  if (mode !== "test" && mode !== "live") throw new Error("INLINE_CHECKOUT_MODE must be test or live")
  return {
    baseUrl: baseUrl.replace(/\/+$/, ""),
    appId,
    live: mode === "live",
    apiToken,
    webhookSecret,
    plans: (plans ?? env["INLINE_CHECKOUT_PLAN"] ?? "").split(",").map((code) => code.trim()).filter(Boolean),
  }
}

export interface CheckoutSessionInfo {
  readonly id: string
  readonly url: string | null
  readonly status: string | null
  readonly paymentStatus: string | null
  readonly subscriptionId: string | null
  readonly paymentIntentId: string | null
  readonly orderId?: string
  readonly plan?: string
}

export interface CheckoutSubscriptionInfo {
  readonly id: string
  readonly status: string
  readonly cancelAtPeriodEnd: boolean
  readonly currentPeriodEnd: number | null
  readonly quantity: number | null
  readonly orderId?: string
  readonly plan?: string
}

export class CheckoutServiceError extends Error {
  constructor(readonly status: number, readonly code: string) {
    super(`checkout service ${status} ${code}`)
  }
}

const request = async <T>(config: CheckoutConfig, method: "GET" | "POST", path: string, body?: unknown): Promise<T> => {
  const response = await fetch(`${config.baseUrl}/v1/apps/${config.appId}${path}`, {
    method,
    headers: {
      authorization: `Bearer ${config.apiToken}`,
      ...(body === undefined ? {} : { "content-type": "application/json" }),
    },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    redirect: "error",
    signal: AbortSignal.timeout(10_000),
  })
  const payload = (await response.json().catch(() => null)) as (T & { error?: string }) | null
  if (!response.ok || !payload) throw new CheckoutServiceError(response.status, payload?.error ?? "invalid_response")
  return payload
}

export const checkoutService = {
  createSession: (config: CheckoutConfig, input: { orderId: string; plan: string; quantity: number; customerEmail?: string }) =>
    request<CheckoutSessionInfo>(config, "POST", "/sessions", input),
  expireSession: (config: CheckoutConfig, id: string) =>
    request<CheckoutSessionInfo>(config, "POST", `/sessions/${encodeURIComponent(id)}/expire`),
  getSession: (config: CheckoutConfig, id: string) =>
    request<CheckoutSessionInfo>(config, "GET", `/sessions/${encodeURIComponent(id)}`),
  getSubscription: (config: CheckoutConfig, id: string) =>
    request<CheckoutSubscriptionInfo>(config, "GET", `/subscriptions/${encodeURIComponent(id)}`),
  setSubscriptionQuantity: (config: CheckoutConfig, id: string, quantity: number) =>
    request<CheckoutSubscriptionInfo>(config, "POST", `/subscriptions/${encodeURIComponent(id)}`, { quantity }),
  createPortal: (config: CheckoutConfig, id: string) =>
    request<{ url: string }>(config, "POST", `/subscriptions/${encodeURIComponent(id)}/portal`),
}
