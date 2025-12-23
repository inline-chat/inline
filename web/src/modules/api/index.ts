/// REST API for auth routes + profile photo upload

import type { TUserInfo } from "@in/server/api-types"
import type { UploadFileResult } from "@in/server/modules/files/types"

type ApiResponseSuccess<T> = { ok: true; result: T }
type ApiResponseFailure = { ok: false; error: string; errorCode?: number; description?: string }
type ApiResponse<T> = ApiResponseSuccess<T> | ApiResponseFailure

export type ApiErrorKind =
  | "api-error"
  | "http-error"
  | "invalid-response"
  | "missing-token"
  | "network-error"
  | "rate-limited"

export class ApiError extends Error {
  readonly kind: ApiErrorKind
  readonly statusCode?: number
  readonly errorCode?: number
  readonly description?: string
  readonly apiError?: string

  constructor(
    kind: ApiErrorKind,
    message: string,
    options?: {
      statusCode?: number
      errorCode?: number
      description?: string
      apiError?: string
    },
  ) {
    super(message)
    this.kind = kind
    this.statusCode = options?.statusCode
    this.errorCode = options?.errorCode
    this.description = options?.description
    this.apiError = options?.apiError
  }
}

export type ApiUser = TUserInfo

export type SendEmailCodeResponse = {
  existingUser?: boolean
}

export type SendSmsCodeResponse = {
  existingUser: boolean
  phoneNumber: string
  formattedPhoneNumber: string
}

export type VerifyCodeResponse = {
  userId: number
  token: string
  user: TUserInfo
}

export type UploadFileResponse = UploadFileResult

export type UpdateProfilePhotoResponse = {
  user: TUserInfo
}

export type AuthContext = {
  deviceId?: string
  clientType?: "web"
  clientVersion?: string
  osVersion?: string
  deviceName?: string
  timezone?: string
}

type ClientConfig = {
  baseUrl: string
  token: string | null
  clientInfo: Partial<AuthContext>
}

const DEFAULT_SERVER_URL = (() => {
  const viteProd = typeof import.meta !== "undefined" ? import.meta.env.PROD : false
  const nodeProd = typeof process !== "undefined" ? process.env.NODE_ENV === "production" : false
  return viteProd || nodeProd ? "https://api.inline.chat" : "http://localhost:8000"
})()

const DEFAULT_BASE_URL = `${DEFAULT_SERVER_URL}/v1`

const clientConfig: ClientConfig = {
  baseUrl: DEFAULT_BASE_URL,
  token: null,
  clientInfo: {},
}

const deviceIdKey = "inline-device-id"
let inMemoryDeviceId: string | null = null

const getStorage = () => {
  if (typeof window === "undefined") return null
  try {
    return window.localStorage
  } catch {
    return null
  }
}

const generateDeviceId = () => {
  if (typeof crypto !== "undefined" && "randomUUID" in crypto) {
    return crypto.randomUUID()
  }
  return `${Date.now()}-${Math.random().toString(16).slice(2)}`
}

const getDeviceId = () => {
  const storage = getStorage()
  if (storage) {
    const existing = storage.getItem(deviceIdKey)
    if (existing) {
      return existing
    }
    const next = generateDeviceId()
    storage.setItem(deviceIdKey, next)
    return next
  }

  if (!inMemoryDeviceId) {
    inMemoryDeviceId = generateDeviceId()
  }

  return inMemoryDeviceId
}

const getDeviceName = () => {
  if (typeof navigator === "undefined") return undefined
  return navigator.userAgent || undefined
}

const getTimeZone = () => {
  try {
    return Intl.DateTimeFormat().resolvedOptions().timeZone
  } catch {
    return undefined
  }
}

const buildAuthContext = (overrides?: AuthContext): AuthContext => {
  return {
    clientType: "web",
    timezone: getTimeZone(),
    deviceName: getDeviceName(),
    deviceId: getDeviceId(),
    ...clientConfig.clientInfo,
    ...overrides,
  }
}

const resolveToken = (token?: string | null) => {
  return token ?? clientConfig.token ?? null
}

const normalizeBaseUrl = (value: string) => value.replace(/\/+$/, "")

const buildUrl = (
  baseUrl: string,
  path: string,
  query?: Record<string, string | number | boolean | null | undefined>,
) => {
  const url = new URL(`${normalizeBaseUrl(baseUrl)}/${path.replace(/^\/+/, "")}`)
  if (query) {
    for (const [key, rawValue] of Object.entries(query)) {
      if (rawValue === undefined || rawValue === null) continue
      url.searchParams.set(key, String(rawValue))
    }
  }
  return url.toString()
}

const parseApiResponse = <T>(response: Response, payload: unknown): T => {
  if (!payload || typeof payload !== "object" || !("ok" in payload)) {
    throw new ApiError("invalid-response", "Invalid API response payload", {
      statusCode: response.status,
    })
  }

  const apiPayload = payload as ApiResponse<T>
  if (apiPayload.ok) {
    return apiPayload.result
  }

  throw new ApiError("api-error", apiPayload.error, {
    statusCode: response.status,
    errorCode: apiPayload.errorCode,
    description: apiPayload.description,
    apiError: apiPayload.error,
  })
}

const readJson = async (response: Response): Promise<unknown> => {
  const text = await response.text()
  if (!text) return null
  return JSON.parse(text)
}

const handleResponse = async <T>(response: Response): Promise<T> => {
  if (response.status === 429) {
    throw new ApiError("rate-limited", "Rate limited", { statusCode: response.status })
  }

  let payload: unknown
  try {
    payload = await readJson(response)
  } catch (error) {
    if (!response.ok) {
      throw new ApiError("http-error", "HTTP error", { statusCode: response.status })
    }
    throw new ApiError("invalid-response", "Failed to parse response JSON", { statusCode: response.status })
  }

  if (payload === null) {
    if (!response.ok) {
      throw new ApiError("http-error", "HTTP error", { statusCode: response.status })
    }
    throw new ApiError("invalid-response", "Empty API response", { statusCode: response.status })
  }

  return parseApiResponse<T>(response, payload)
}

const requestJson = async <T>(
  path: string,
  options: {
    method: "GET" | "POST"
    query?: Record<string, string | number | boolean | null | undefined>
    body?: Record<string, unknown>
    token?: string | null
    includeToken?: boolean
  },
): Promise<T> => {
  const url = buildUrl(clientConfig.baseUrl, path, options.query)
  const headers = new Headers()
  headers.set("Accept", "application/json")

  if (options.body) {
    headers.set("Content-Type", "application/json")
  }

  const token = options.includeToken ? resolveToken(options.token) : null
  if (options.includeToken && !token) {
    throw new ApiError("missing-token", "Missing auth token")
  }
  if (token) {
    headers.set("Authorization", `Bearer ${token}`)
  }

  try {
    const response = await fetch(url, {
      method: options.method,
      headers,
      body: options.body ? JSON.stringify(options.body) : undefined,
    })

    return await handleResponse<T>(response)
  } catch (error) {
    if (error instanceof ApiError) throw error
    throw new ApiError("network-error", "Network error")
  }
}

const requestMultipart = async <T>(
  path: string,
  formData: FormData,
  options: {
    token?: string | null
    onProgress?: (progress: number) => void
  },
): Promise<T> => {
  const token = resolveToken(options.token)
  if (!token) {
    throw new ApiError("missing-token", "Missing auth token")
  }

  const url = buildUrl(clientConfig.baseUrl, path)

  if (typeof XMLHttpRequest !== "undefined") {
    return await new Promise<T>((resolve, reject) => {
      const xhr = new XMLHttpRequest()
      xhr.open("POST", url)
      xhr.setRequestHeader("Authorization", `Bearer ${token}`)
      xhr.responseType = "text"

      xhr.onerror = () => {
        reject(new ApiError("network-error", "Network error"))
      }

      xhr.onload = () => {
        try {
          if (xhr.status === 429) {
            reject(new ApiError("rate-limited", "Rate limited", { statusCode: xhr.status }))
            return
          }

          const payload = xhr.responseText ? JSON.parse(xhr.responseText) : null
          if (!payload) {
            reject(new ApiError("invalid-response", "Empty API response", { statusCode: xhr.status }))
            return
          }

          const result = parseApiResponse<T>(new Response(null, { status: xhr.status }), payload)
          resolve(result)
        } catch (error) {
          reject(new ApiError("invalid-response", "Failed to parse response JSON", { statusCode: xhr.status }))
        }
      }

      if (options.onProgress) {
        xhr.upload.onprogress = (event) => {
          if (!event.lengthComputable) return
          options.onProgress?.(Math.min(Math.max(event.loaded / event.total, 0), 1))
        }
      }

      options.onProgress?.(0)
      xhr.send(formData)
    })
  }

  try {
    const response = await fetch(url, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${token}`,
      },
      body: formData,
    })
    options.onProgress?.(1)
    return await handleResponse<T>(response)
  } catch (error) {
    if (error instanceof ApiError) throw error
    throw new ApiError("network-error", "Network error")
  }
}

export type UploadPhotoInput = {
  file: File | Blob
  filename?: string
  mimeType?: string
  token?: string | null
  onProgress?: (progress: number) => void
}

export type UploadProfilePhotoResult = {
  upload: UploadFileResponse
  profile: UpdateProfilePhotoResponse
}

export const ApiClient = {
  setBaseUrl: (baseUrl: string) => {
    clientConfig.baseUrl = normalizeBaseUrl(baseUrl)
  },

  setToken: (token: string | null) => {
    clientConfig.token = token
  },

  setClientInfo: (clientInfo: Partial<AuthContext>) => {
    clientConfig.clientInfo = {
      ...clientConfig.clientInfo,
      ...clientInfo,
    }
  },

  sendEmailCode: async (email: string) => {
    return await requestJson<SendEmailCodeResponse>("sendEmailCode", {
      method: "GET",
      query: { email },
      includeToken: false,
    })
  },

  sendSmsCode: async (phoneNumber: string) => {
    return await requestJson<SendSmsCodeResponse>("sendSmsCode", {
      method: "POST",
      body: { phoneNumber },
      includeToken: false,
    })
  },

  verifyEmailCode: async (code: string, email: string, context?: AuthContext) => {
    const authContext = buildAuthContext(context)
    return await requestJson<VerifyCodeResponse>("verifyEmailCode", {
      method: "GET",
      query: {
        code,
        email,
        deviceId: authContext.deviceId,
        clientType: authContext.clientType,
        clientVersion: authContext.clientVersion,
        osVersion: authContext.osVersion,
        deviceName: authContext.deviceName,
        timezone: authContext.timezone,
      },
      includeToken: false,
    })
  },

  verifySmsCode: async (code: string, phoneNumber: string, context?: AuthContext) => {
    const authContext = buildAuthContext(context)
    return await requestJson<VerifyCodeResponse>("verifySmsCode", {
      method: "POST",
      body: {
        code,
        phoneNumber,
        deviceId: authContext.deviceId,
        clientType: authContext.clientType,
        clientVersion: authContext.clientVersion,
        osVersion: authContext.osVersion,
        deviceName: authContext.deviceName,
        timezone: authContext.timezone,
      },
      includeToken: false,
    })
  },

  uploadPhoto: async ({ file, filename, mimeType, token, onProgress }: UploadPhotoInput) => {
    const formData = new FormData()
    formData.append("type", "photo")
    const fileName = filename ?? (file instanceof File ? file.name : "photo")
    const contentType = mimeType ?? (file instanceof File ? file.type : undefined)
    const uploadFile = contentType ? new File([file], fileName, { type: contentType }) : file
    formData.append("file", uploadFile, fileName)

    return await requestMultipart<UploadFileResponse>("uploadFile", formData, {
      token,
      onProgress,
    })
  },

  updateProfilePhoto: async (fileUniqueId: string, token?: string | null) => {
    return await requestJson<UpdateProfilePhotoResponse>("updateProfilePhoto", {
      method: "GET",
      query: { fileUniqueId },
      includeToken: true,
      token,
    })
  },

  uploadProfilePhoto: async ({ file, filename, mimeType, token, onProgress }: UploadPhotoInput) => {
    const upload = await ApiClient.uploadPhoto({ file, filename, mimeType, token, onProgress })
    const profile = await ApiClient.updateProfilePhoto(upload.fileUniqueId, token)
    return { upload, profile } satisfies UploadProfilePhotoResult
  },
}
