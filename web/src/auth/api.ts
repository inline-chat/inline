import { parseInlineId } from "@inline/ids"
import type { AuthSession } from "@inline/auth/core"

export class AuthApiError extends Error {}

export class AuthApi {
  constructor(private readonly origin: string) {}

  private async request(
    path: string,
    params: Record<string, string>,
    token?: string
  ): Promise<Record<string, unknown>> {
    const url = new URL(`/v1/${path}`, this.origin)
    const response = await fetch(url, {
      method: "POST",
      body: JSON.stringify(params),
      headers: {
        Accept: "application/json",
        "Content-Type": "application/json",
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
      },
      cache: "no-store",
      referrerPolicy: "no-referrer",
      signal: AbortSignal.timeout(20_000),
    })
    if (response.status === 429)
      throw new AuthApiError("Too many attempts. Please try again in a little while.")
    const body = await response.json().catch(() => null)
    if (!response.ok || body?.ok !== true || !body.result || typeof body.result !== "object") {
      throw new AuthApiError(
        typeof body?.description === "string"
          ? body.description
          : "Could not complete sign-in. Please try again."
      )
    }
    return body.result
  }

  async sendCode(email: string): Promise<string | undefined> {
    const result = await this.request("sendEmailCode", { email })
    return typeof result.challengeToken === "string" ? result.challengeToken : undefined
  }

  async verify(email: string, code: string, challengeToken?: string): Promise<AuthSession> {
    let deviceId: string
    try {
      deviceId = localStorage.getItem("inline-web-device") ?? crypto.randomUUID()
      localStorage.setItem("inline-web-device", deviceId)
    } catch {
      deviceId = crypto.randomUUID()
    }
    const result = await this.request("verifyEmailCode", {
      email,
      code,
      ...(challengeToken ? { challengeToken } : {}),
      deviceId,
      clientType: "web",
      clientVersion: "web-foundation-1",
      deviceName: navigator.userAgent,
      timezone: Intl.DateTimeFormat().resolvedOptions().timeZone,
    })
    const userId = parseInlineId<"user">(result.userId, { positive: true })
    if (!userId || typeof result.token !== "string" || !result.token)
      throw new AuthApiError("The server returned an invalid session.")
    return { userId, token: result.token }
  }

  async logout(token: string): Promise<void> {
    const response = await fetch(new URL("/v1/logout", this.origin), {
      method: "POST",
      headers: { Accept: "application/json", Authorization: `Bearer ${token}` },
      cache: "no-store",
      referrerPolicy: "no-referrer",
      signal: AbortSignal.timeout(20_000),
    })
    const body = await response.json().catch(() => null)
    if (!response.ok || body?.ok !== true) throw new AuthApiError("Could not revoke the session.")
  }
}
