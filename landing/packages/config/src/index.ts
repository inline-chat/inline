export type InlineConfig = {
  serverUrl: string
  apiBaseUrl: string
  realtimeUrl: string
}

export type InlineConfigOverrides = Partial<InlineConfig>

const isProd = () => {
  const viteProd = typeof import.meta !== "undefined" && Boolean(import.meta.env?.PROD)
  const nodeProd = typeof process !== "undefined" && process.env.NODE_ENV === "production"
  return viteProd || nodeProd
}

const normalizeUrl = (url: string) => url.replace(/\/+$/, "")

const toWebSocketUrl = (url: string) => {
  if (url.startsWith("https://")) return `wss://${url.slice("https://".length)}`
  if (url.startsWith("http://")) return `ws://${url.slice("http://".length)}`
  return url
}

const resolveEnv = (key: string) => {
  if (typeof import.meta !== "undefined") {
    const envValue = (import.meta as { env?: Record<string, string | undefined> }).env?.[key]
    if (envValue) return envValue
  }

  if (typeof process !== "undefined" && process.env[key]) {
    return process.env[key]
  }

  return undefined
}

const resolveDefaultServerUrl = () => {
  const envUrl = resolveEnv("VITE_SERVER_URL")
  if (envUrl) return normalizeUrl(envUrl)
  return isProd() ? "https://api.inline.chat" : "http://localhost:8000"
}

const deriveRealtimeUrl = (serverUrl: string) => `${toWebSocketUrl(normalizeUrl(serverUrl))}/realtime`

const resolveConfig = (overrides: InlineConfigOverrides = {}): InlineConfig => {
  const envServerUrl = resolveEnv("VITE_SERVER_URL")
  const envApiBaseUrl = resolveEnv("VITE_API_BASE_URL")
  const envRealtimeUrl = resolveEnv("VITE_REALTIME_URL")

  const serverUrl = normalizeUrl(overrides.serverUrl ?? envServerUrl ?? resolveDefaultServerUrl())
  const apiBaseUrl = normalizeUrl(overrides.apiBaseUrl ?? envApiBaseUrl ?? `${serverUrl}/v1`)
  const realtimeUrl = normalizeUrl(overrides.realtimeUrl ?? envRealtimeUrl ?? deriveRealtimeUrl(serverUrl))

  return { serverUrl, apiBaseUrl, realtimeUrl }
}

let overrides: InlineConfigOverrides = {}

export const getConfig = () => resolveConfig(overrides)

export const setConfig = (next: InlineConfigOverrides) => {
  overrides = { ...overrides, ...next }
}

export const getServerUrl = () => getConfig().serverUrl
export const getApiBaseUrl = () => getConfig().apiBaseUrl
export const getRealtimeUrl = () => getConfig().realtimeUrl

export const resolveRealtimeUrl = (serverUrl = getServerUrl()) => deriveRealtimeUrl(serverUrl)
