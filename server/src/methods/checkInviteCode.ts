import { Type } from "@sinclair/typebox"
import type { Static } from "elysia"
import { InlineError } from "@in/server/types/errors"
import type { UnauthenticatedHandlerContext } from "@in/server/controllers/helpers"
import { InviteCodesModel, isDevInviteCode, isValidInviteCode, normalizeInviteCode } from "@in/server/db/models/inviteCodes"
import { InMemoryRateLimiter } from "@in/server/modules/oauth/rateLimiter"

export const Input = Type.Object({
  inviteCode: Type.String({ maxLength: 64 }),
})

export const Response = Type.Object({
  valid: Type.Boolean(),
})

const limiter = new InMemoryRateLimiter()
const perIpRule = { max: 20, windowMs: 10 * 60_000 }
const perCodeRule = { max: 5, windowMs: 10 * 60_000 }

export const handler = async (
  input: Static<typeof Input>,
  context: UnauthenticatedHandlerContext,
): Promise<Static<typeof Response>> => {
  const code = normalizeInviteCode(input.inviteCode)
  checkRateLimit(context.ip, code)

  if (!code) {
    throw new InlineError(InlineError.ApiError.INVITE_CODE_REQUIRED)
  }

  if (!isValidInviteCode(code)) {
    throw new InlineError(InlineError.ApiError.INVITE_CODE_INVALID)
  }

  if (isDevInviteCode(code)) {
    return { valid: true }
  }

  const row = await InviteCodesModel.getByCode({ code })
  if (!row) {
    throw new InlineError(InlineError.ApiError.INVITE_CODE_NOT_FOUND)
  }

  if (row.redeemedAt) {
    throw new InlineError(InlineError.ApiError.INVITE_CODE_TAKEN)
  }

  return { valid: true }
}

const checkRateLimit = (ip: string | undefined, code: string) => {
  const nowMs = Date.now()
  limiter.cleanup(nowMs)

  const ipKey = normalizeRateLimitPart(ip ?? "unknown")
  const codeKey = normalizeRateLimitPart(code || "empty")

  const ipResult = limiter.consume({
    key: `invite-check:ip:${ipKey}`,
    nowMs,
    rule: perIpRule,
  })
  if (!ipResult.allowed) {
    throw new InlineError(InlineError.ApiError.FLOOD)
  }

  const codeResult = limiter.consume({
    key: `invite-check:ip-code:${ipKey}:${codeKey}`,
    nowMs,
    rule: perCodeRule,
  })
  if (!codeResult.allowed) {
    throw new InlineError(InlineError.ApiError.FLOOD)
  }
}

const normalizeRateLimitPart = (value: string) => value.split(",")[0]?.trim().toLowerCase().slice(0, 80) || "unknown"
