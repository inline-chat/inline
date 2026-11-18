/**
 * A stable device ID for this browser profile and a readable device name.
 *
 * The ID identifies the browser profile, not an account: it is created once,
 * kept in the injected storage (localStorage in the app), and sent with every
 * sign-in so the server's session list can tell devices apart. It is not a
 * secret. The server keeps at most 128 characters
 * (modules/oauth/httpHandlers.ts PROVIDER_CLIENT_METADATA_LIMITS).
 */

import type { DeviceFacts } from "./api"

/** Synchronous key-value storage; `localStorage` and `sessionStorage` fit. */
export interface KeyValueStorage {
  getItem(key: string): string | null
  setItem(key: string, value: string): void
  removeItem(key: string): void
}

export const DEVICE_ID_STORAGE_KEY = "inline:device-id"

const VALID_DEVICE_ID = /^[A-Za-z0-9_-]{8,128}$/

export type DeviceIdResult = {
  deviceId: string
  /** False when storage was unavailable; the ID then lasts for this page only. */
  persisted: boolean
}

export type LoadDeviceIdOptions = {
  storage: KeyValueStorage | null
  /** A new random ID. The app passes `() => crypto.randomUUID()`. */
  randomId: () => string
  key?: string
}

export const loadDeviceId = (options: LoadDeviceIdOptions): DeviceIdResult => {
  const key = options.key ?? DEVICE_ID_STORAGE_KEY
  const storage = options.storage
  if (storage) {
    try {
      const existing = storage.getItem(key)
      if (existing != null && VALID_DEVICE_ID.test(existing)) {
        return { deviceId: existing, persisted: true }
      }
    } catch {
      // Fall through to a fresh ID.
    }
  }

  const deviceId = options.randomId()
  if (!VALID_DEVICE_ID.test(deviceId)) {
    throw new TypeError("Inline device ID generator returned an invalid ID")
  }
  if (!storage) return { deviceId, persisted: false }
  try {
    storage.setItem(key, deviceId)
    return { deviceId, persisted: storage.getItem(key) === deviceId }
  } catch {
    return { deviceId, persisted: false }
  }
}

// ---------------------------------------------------------------------------
// Device name

export type UserAgentEnvironment = {
  userAgent: string
  /** `navigator.userAgentData` where the browser has it (Chromium). */
  userAgentData?: {
    platform?: string
    brands?: ReadonlyArray<{ brand: string; version: string }>
    mobile?: boolean
  }
}

export type DeviceDescription = {
  browser: string
  os: string
  /** For example "Chrome on macOS" or "Inline Desktop on Windows". */
  name: string
}

const browserFromUserAgent = (env: UserAgentEnvironment): string => {
  const ua = env.userAgent
  if (/\bElectron\//.test(ua)) return "Inline Desktop"
  const brands = env.userAgentData?.brands?.map((entry) => entry.brand) ?? []
  if (brands.includes("Microsoft Edge") || /\bEdg(A|iOS)?\//.test(ua)) return "Edge"
  if (brands.includes("Opera") || /\bOPR\//.test(ua)) return "Opera"
  if (brands.includes("Brave")) return "Brave"
  if (/\b(Firefox|FxiOS)\//.test(ua)) return "Firefox"
  if (brands.includes("Google Chrome") || /\b(Chrome|CriOS)\//.test(ua)) return "Chrome"
  if (brands.includes("Chromium") || /\bChromium\//.test(ua)) return "Chromium"
  if (/\bSafari\//.test(ua) && /\bVersion\//.test(ua)) return "Safari"
  return "Browser"
}

const osFromUserAgent = (env: UserAgentEnvironment): string => {
  const ua = env.userAgent
  const platform = env.userAgentData?.platform?.toLowerCase() ?? ""
  if (/\biPad\b/.test(ua)) return "iPadOS"
  if (/\b(iPhone|iPod)\b/.test(ua)) return "iOS"
  if (platform === "android" || /\bAndroid\b/.test(ua)) return "Android"
  if (platform === "chrome os" || platform === "chromeos" || /\bCrOS\b/.test(ua)) return "ChromeOS"
  if (platform === "macos" || /\bMac OS X\b|\bMacintosh\b/.test(ua)) return "macOS"
  if (platform === "windows" || /\bWindows\b/.test(ua)) return "Windows"
  if (platform === "linux" || /\bLinux\b/.test(ua)) return "Linux"
  return "Unknown OS"
}

export const describeDevice = (env: UserAgentEnvironment): DeviceDescription => {
  const browser = browserFromUserAgent(env)
  const os = osFromUserAgent(env)
  return { browser, os, name: os === "Unknown OS" ? browser : `${browser} on ${os}` }
}

// ---------------------------------------------------------------------------
// Facts for the API client

export type CreateDeviceFactsOptions = LoadDeviceIdOptions & {
  environment: UserAgentEnvironment
  clientVersion?: string
  osVersion?: string
  timeZone?: string
}

export const createDeviceFacts = (
  options: CreateDeviceFactsOptions,
): DeviceFacts & { deviceIdPersisted: boolean } => {
  const { deviceId, persisted } = loadDeviceId(options)
  return {
    deviceId,
    deviceIdPersisted: persisted,
    deviceName: describeDevice(options.environment).name,
    ...(options.clientVersion ? { clientVersion: options.clientVersion } : {}),
    ...(options.osVersion ? { osVersion: options.osVersion } : {}),
    ...(options.timeZone ? { timeZone: options.timeZone } : {}),
  }
}
