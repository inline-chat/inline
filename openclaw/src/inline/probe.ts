import { InlineSdkClient, Method, type User } from "@inline-chat/realtime-sdk"
import type { ResolvedInlineAccount } from "./accounts.js"
import { resolveInlineToken } from "./accounts.js"

export type InlineProbe = {
  ok: boolean
  accountId: string
  baseUrl: string | null
  user?: {
    id: string
    username: string | null
    name: string
    bot: boolean
  }
  error?: string
}

function formatInlineProbeUserName(user: User): string {
  const explicit = [user.firstName?.trim(), user.lastName?.trim()].filter(Boolean).join(" ")
  if (explicit) return explicit
  const username = user.username?.trim()
  if (username) return `@${username}`
  return "Unknown"
}

async function withTimeout<T>(promise: Promise<T>, timeoutMs: number): Promise<T> {
  if (!Number.isFinite(timeoutMs) || timeoutMs <= 0) {
    return await promise
  }
  return await new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => {
      reject(new Error(`probe timeout after ${Math.trunc(timeoutMs)}ms`))
    }, timeoutMs)
    void promise.then(
      (value) => {
        clearTimeout(timer)
        resolve(value)
      },
      (error: unknown) => {
        clearTimeout(timer)
        reject(error)
      },
    )
  })
}

async function probeInlineAccountDirect(account: ResolvedInlineAccount): Promise<InlineProbe> {
  if (!account.baseUrl?.trim()) {
    throw new Error("missing baseUrl")
  }
  const token = await resolveInlineToken(account)
  const client = new InlineSdkClient({
    baseUrl: account.baseUrl,
    token,
  })
  await client.connect()
  try {
    const result = await client.invokeRaw(Method.GET_ME, {
      oneofKind: "getMe",
      getMe: {},
    })
    if (result.oneofKind !== "getMe") {
      throw new Error(`expected getMe result, got ${String(result.oneofKind)}`)
    }
    if (!result.getMe.user) {
      throw new Error("missing current user from getMe")
    }
    const user = result.getMe.user
    return {
      ok: true,
      accountId: account.accountId,
      baseUrl: account.baseUrl,
      user: {
        id: String(user.id),
        username: user.username?.trim() || null,
        name: formatInlineProbeUserName(user),
        bot: user.bot ?? false,
      },
    }
  } finally {
    await client.close().catch(() => {})
  }
}

function toErrorText(error: unknown): string {
  if (error instanceof Error && error.message.trim()) {
    return error.message
  }
  return String(error)
}

export async function probeInlineAccount(
  account: ResolvedInlineAccount,
  timeoutMs: number,
): Promise<InlineProbe> {
  if (!account.configured) {
    return {
      ok: false,
      accountId: account.accountId,
      baseUrl: account.baseUrl,
      error: "missing token",
    }
  }
  try {
    return await withTimeout(probeInlineAccountDirect(account), timeoutMs)
  } catch (error) {
    return {
      ok: false,
      accountId: account.accountId,
      baseUrl: account.baseUrl,
      error: toErrorText(error),
    }
  }
}
