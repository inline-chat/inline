import type { DbBillingSubscription } from "@in/server/db/schema"
import {
  availablePlans,
  BillingError,
  createCheckout,
  createPortal,
  manageableSpaceIds,
  subjectBilling,
} from "@in/server/modules/billing/service"
import { InMemoryRateLimiter } from "@in/server/modules/oauth/rateLimiter"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import type { HandlerContext } from "@in/server/realtime/types"
import type {
  BillingAccount,
  BillingSubscription,
  CreateBillingCheckoutInput,
  CreateBillingCheckoutResult,
  CreateBillingPortalInput,
  CreateBillingPortalResult,
  GetBillingInput,
  GetBillingResult,
} from "@inline-chat/protocol/core"

const billingLimiter = new InMemoryRateLimiter({ capacity: 10_000 })

const limit = (context: HandlerContext, kind: string, max: number) => {
  const rate = billingLimiter.consume({ key: `billing-${kind}:${context.userId}`, nowMs: Date.now(), rule: { max, windowMs: 60_000 } })
  if (!rate.allowed) throw RealtimeRpcError.RateLimit()
}

const toRpcError = (error: unknown): unknown => {
  if (!(error instanceof BillingError)) return error
  switch (error.code) {
    case "not_space_admin":
      return RealtimeRpcError.SpaceAdminRequired()
    case "checkout_failed":
      return RealtimeRpcError.ServiceUnavailable(5)
    default:
      return RealtimeRpcError.BadRequestWithReason(error.code)
  }
}

const spaceIdOf = (value: bigint | undefined) => {
  if (value === undefined) return undefined
  const spaceId = Number(value)
  if (!Number.isSafeInteger(spaceId) || spaceId <= 0) throw RealtimeRpcError.SpaceIdInvalid()
  return spaceId
}

const encodeSubscription = (subscription: DbBillingSubscription, viewerUserId: number): BillingSubscription => ({
  plan: subscription.plan,
  interval: subscription.interval,
  funding: subscription.funding,
  status: subscription.status,
  seats: subscription.seats,
  paidThrough: subscription.paidThrough ? BigInt(Math.floor(subscription.paidThrough.getTime() / 1000)) : undefined,
  cancelAtPeriodEnd: subscription.cancelAtPeriodEnd,
  canManage: subscription.funding === "stripe" && subscription.payerUserId === viewerUserId,
})

const encodeAccount = async (subject: { userId: number } | { spaceId: number }, viewerUserId: number): Promise<BillingAccount> => {
  const billing = await subjectBilling(subject)
  const hasWallet = billing.wallet.usd !== undefined || billing.wallet.btc !== undefined
  return {
    spaceId: "spaceId" in subject ? BigInt(subject.spaceId) : undefined,
    isPro: billing.isPro,
    subscription: billing.subscription ? encodeSubscription(billing.subscription, viewerUserId) : undefined,
    wallet: hasWallet
      ? {
          usdCents: billing.wallet.usd !== undefined ? BigInt(billing.wallet.usd) : undefined,
          btcSats: billing.wallet.btc !== undefined ? BigInt(billing.wallet.btc) : undefined,
        }
      : undefined,
  }
}

export async function getBillingHandler(_input: GetBillingInput, context: HandlerContext): Promise<GetBillingResult> {
  limit(context, "get", 60)
  if (context.isBot) throw RealtimeRpcError.BadRequestWithReason("billing_unavailable")
  const spaceIds = await manageableSpaceIds(context.userId)
  return {
    me: await encodeAccount({ userId: context.userId }, context.userId),
    spaces: await Promise.all(spaceIds.map((spaceId) => encodeAccount({ spaceId }, context.userId))),
    plans: availablePlans().map((plan) => ({
      code: plan.code,
      plan: plan.plan,
      interval: plan.interval,
      forSpace: plan.subject === "space",
      usdCents: BigInt(plan.usdCents),
      perSeat: plan.perSeat,
    })),
  }
}

export async function createBillingCheckoutHandler(
  input: CreateBillingCheckoutInput,
  context: HandlerContext,
): Promise<CreateBillingCheckoutResult> {
  limit(context, "checkout", 10)
  if (context.isBot) throw RealtimeRpcError.BadRequestWithReason("billing_unavailable")
  try {
    const spaceId = spaceIdOf(input.spaceId)
    const { url } = await createCheckout({ userId: context.userId, planCode: input.plan, ...(spaceId ? { spaceId } : {}) })
    return { url }
  } catch (error) {
    throw toRpcError(error)
  }
}

export async function createBillingPortalHandler(
  input: CreateBillingPortalInput,
  context: HandlerContext,
): Promise<CreateBillingPortalResult> {
  limit(context, "portal", 10)
  if (context.isBot) throw RealtimeRpcError.BadRequestWithReason("billing_unavailable")
  try {
    const spaceId = spaceIdOf(input.spaceId)
    return await createPortal({ userId: context.userId, ...(spaceId ? { spaceId } : {}) })
  } catch (error) {
    throw toRpcError(error)
  }
}
