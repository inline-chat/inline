import { getApiBaseUrl } from "@inline/config"
import { parseInlineId, type UserID } from "@inline/ids"

type ApiSuccess<T> = {
  ok: true
  result: T
}

type ApiFailure = {
  ok: false
  error: string
  errorCode?: number
  description?: string
}

export type InlineAuthUser = {
  id: UserID
  firstName?: string
  lastName?: string
  username?: string
  email?: string
  pendingSetup?: boolean
}

export type SendEmailCodeResult = {
  existingUser: boolean
  needsInviteCode: boolean
  challengeToken?: string
}

export type SendSmsCodeResult = {
  existingUser: boolean
  needsInviteCode: boolean
  phoneNumber: string
  formattedPhoneNumber: string
}

export type VerifyCodeResult = {
  userId: UserID
  token: string
  user: InlineAuthUser
}

export type VerifyEmailCodeResult = VerifyCodeResult

export type UpdateProfileResult = {
  user: InlineAuthUser
}

export class InlineAuthError extends Error {
  readonly errorCode?: number
  readonly apiError?: string

  constructor(message: string, options?: { errorCode?: number; apiError?: string }) {
    super(message)
    this.name = "InlineAuthError"
    this.errorCode = options?.errorCode
    this.apiError = options?.apiError
  }
}

type InlineAuthUserWire = Omit<InlineAuthUser, "id"> & {
  id: unknown
}

type VerifyCodeWire = Omit<VerifyCodeResult, "userId" | "user"> & {
  userId: unknown
  user: InlineAuthUserWire
}

type UpdateProfileWire = {
  user: InlineAuthUserWire
}

const invalidAuthResponse = () =>
  new InlineAuthError("Inline returned an invalid authentication response.")

const decodeUser = (value: InlineAuthUserWire): InlineAuthUser => {
  const id = parseInlineId<"user">(value.id, { positive: true })
  if (!id) throw invalidAuthResponse()
  return { ...value, id }
}

const decodeVerifyCodeResult = (result: VerifyCodeWire): VerifyCodeResult => {
  const userId = parseInlineId<"user">(result.userId, { positive: true })
  if (!userId || typeof result.token !== "string" || result.token.length === 0) {
    throw invalidAuthResponse()
  }
  const user = decodeUser(result.user)
  if (user.id !== userId) throw invalidAuthResponse()
  return { ...result, userId, user }
}

const deviceIdKey = "inline-web-device-id"
let memoryDeviceId: string | undefined

const getDeviceId = () => {
  if (memoryDeviceId) return memoryDeviceId

  const generated =
    typeof crypto !== "undefined" && "randomUUID" in crypto
      ? crypto.randomUUID()
      : `${Date.now()}-${Math.random().toString(16).slice(2)}`

  if (typeof window === "undefined") {
    memoryDeviceId = generated
    return generated
  }

  try {
    const stored = window.localStorage.getItem(deviceIdKey)
    if (stored) {
      memoryDeviceId = stored
      return stored
    }
    window.localStorage.setItem(deviceIdKey, generated)
  } catch {
    // A stable in-memory ID still keeps the request valid in restricted contexts.
  }

  memoryDeviceId = generated
  return generated
}

const clientInfo = () => ({
  deviceId: getDeviceId(),
  clientType: "web",
  clientVersion: "0.0.0",
  deviceName: typeof navigator === "undefined" ? "Inline Web" : `Inline Web · ${navigator.platform}`,
  timezone: Intl.DateTimeFormat().resolvedOptions().timeZone,
})

const request = async <T>(
  path: string,
  options: {
    method: "GET" | "POST"
    body?: Record<string, unknown>
    query?: Record<string, string | number | undefined>
    token?: string
  },
): Promise<T> => {
  const url = new URL(`${getApiBaseUrl()}/${path}`)
  for (const [key, value] of Object.entries(options.query ?? {})) {
    if (value !== undefined) url.searchParams.set(key, String(value))
  }

  const headers = new Headers({ Accept: "application/json" })
  if (options.body) headers.set("Content-Type", "application/json")
  if (options.token) headers.set("Authorization", `Bearer ${options.token}`)

  let response: Response
  try {
    response = await fetch(url, {
      method: options.method,
      headers,
      body: options.body ? JSON.stringify(options.body) : undefined,
    })
  } catch {
    throw new InlineAuthError("Could not connect to Inline.")
  }

  let payload: ApiSuccess<T> | ApiFailure
  try {
    payload = (await response.json()) as ApiSuccess<T> | ApiFailure
  } catch {
    throw new InlineAuthError(response.ok ? "Inline returned an invalid response." : "Inline is unavailable.")
  }

  if (!response.ok || !payload.ok) {
    const failure = payload as ApiFailure
    throw new InlineAuthError(failure.description ?? failure.error ?? "The request failed.", {
      errorCode: failure.errorCode,
      apiError: failure.error,
    })
  }

  return payload.result
}

export const inlineAuthApi = {
  sendEmailCode: async (email: string) => {
    const info = clientInfo()
    return await request<SendEmailCodeResult>("sendEmailCode", {
      method: "GET",
      query: {
        email,
        deviceId: info.deviceId,
        clientType: info.clientType,
        clientVersion: info.clientVersion,
        deviceName: info.deviceName,
      },
    })
  },

  sendSmsCode: async (phoneNumber: string) => {
    const info = clientInfo()
    return await request<SendSmsCodeResult>("sendSmsCode", {
      method: "POST",
      body: {
        phoneNumber,
        deviceId: info.deviceId,
        clientType: info.clientType,
        clientVersion: info.clientVersion,
        deviceName: info.deviceName,
      },
    })
  },

  checkInviteCode: async (inviteCode: string) =>
    await request<{ valid: boolean }>("checkInviteCode", {
      method: "POST",
      body: { inviteCode },
    }),

  verifyEmailCode: async (input: {
    email: string
    code: string
    challengeToken?: string
    inviteCode?: string
  }) => {
    const info = clientInfo()
    const result = await request<VerifyCodeWire>("verifyEmailCode", {
      method: "GET",
      query: {
        ...input,
        deviceId: info.deviceId,
        clientType: info.clientType,
        clientVersion: info.clientVersion,
        deviceName: info.deviceName,
        timezone: info.timezone,
      },
    })
    return decodeVerifyCodeResult(result)
  },

  verifySmsCode: async (input: {
    phoneNumber: string
    code: string
    inviteCode?: string
  }) => {
    const info = clientInfo()
    const result = await request<VerifyCodeWire>("verifySmsCode", {
      method: "POST",
      body: {
        ...input,
        deviceId: info.deviceId,
        clientType: info.clientType,
        clientVersion: info.clientVersion,
        deviceName: info.deviceName,
        timezone: info.timezone,
      },
    })
    return decodeVerifyCodeResult(result)
  },

  updateProfile: async (
    input: {
      firstName: string
      lastName?: string
      username?: string
    },
    token: string,
  ) => {
    const result = await request<UpdateProfileWire>("updateProfile", {
      method: "POST",
      token,
      body: {
        ...input,
        timeZone: Intl.DateTimeFormat().resolvedOptions().timeZone,
      },
    })
    return { user: decodeUser(result.user) }
  },
}
