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

const maximumProbeCleanupHeadroomMs = 2_500

function formatInlineProbeUserName(user: User): string {
  const explicit = [user.firstName?.trim(), user.lastName?.trim()].filter(Boolean).join(" ")
  if (explicit) return explicit
  const username = user.username?.trim()
  if (username) return `@${username}`
  return "Unknown"
}

function probeOperationTimeoutMs(timeoutMs: number): number | null {
  if (!Number.isFinite(timeoutMs) || timeoutMs <= 0) return null

  const totalMs = Math.max(1, Math.trunc(timeoutMs))
  // InlineSdkClient.close() has bounded transport cleanup. Finish the network
  // work early enough for cleanup and for OpenClaw to serialize the result
  // before its own timeout at the same caller-provided deadline.
  const cleanupHeadroomMs = Math.min(
    maximumProbeCleanupHeadroomMs,
    Math.max(100, Math.floor(totalMs * 0.8)),
    Math.max(0, totalMs - 1),
  )
  return Math.max(1, totalMs - cleanupHeadroomMs)
}

async function probeInlineAccountDirect(
  account: ResolvedInlineAccount,
  signal: AbortSignal | undefined,
  operationTimeoutMs: number | null,
): Promise<InlineProbe> {
  if (!account.baseUrl?.trim()) {
    throw new Error("missing baseUrl")
  }
  const token = await resolveInlineToken(account)
  const client = new InlineSdkClient({
    baseUrl: account.baseUrl,
    token,
    ...(operationTimeoutMs == null ? {} : { rpcTimeoutMs: operationTimeoutMs }),
  })
  try {
    await client.connect(signal)
    const result = await client.invokeRaw(Method.GET_ME, {
      oneofKind: "getMe",
      getMe: {},
    }, operationTimeoutMs == null
      ? undefined
      : {
          ...(signal ? { signal } : {}),
          timeoutMs: operationTimeoutMs,
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

function probeTimeoutError(timeoutMs: number): string {
  return `probe timeout after ${Math.trunc(timeoutMs)}ms`
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

  const operationTimeoutMs = probeOperationTimeoutMs(timeoutMs)
  let controller: AbortController | undefined
  let timer: ReturnType<typeof setTimeout> | undefined
  if (operationTimeoutMs != null) {
    controller = new AbortController()
    timer = setTimeout(() => controller?.abort(), operationTimeoutMs)
  }
  timer?.unref?.()
  try {
    return await probeInlineAccountDirect(
      account,
      controller?.signal,
      operationTimeoutMs,
    )
  } catch (error) {
    return {
      ok: false,
      accountId: account.accountId,
      baseUrl: account.baseUrl,
      error: controller?.signal.aborted
        ? probeTimeoutError(timeoutMs)
        : toErrorText(error),
    }
  } finally {
    if (timer != null) clearTimeout(timer)
  }
}
