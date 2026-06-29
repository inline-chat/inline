import Constants from "expo-constants"

type Extra = {
  apiBaseUrl?: string
  apiWsUrl?: string
  appEnv?: string
  sentryDsn?: string
  sentryTracesSampleRate?: string | number
  eas?: {
    projectId?: string
  }
}

const extra = (Constants.expoConfig?.extra ?? {}) as Extra
const androidPackage = Constants.expoConfig?.android?.package ?? "chat.inline.android"
const version = Constants.expoConfig?.version ?? "0.1.0"

export const appConfig = {
  apiBaseUrl: extra.apiBaseUrl ?? "https://api.inline.chat",
  apiWsUrl: extra.apiWsUrl ?? "wss://api.inline.chat/realtime",
  environment: extra.appEnv ?? "production",
  projectId: extra.eas?.projectId,
  version,
  androidPackage,
  sentryDsn: normalizeOptionalString(extra.sentryDsn),
  sentryTracesSampleRate: sampleRate(extra.sentryTracesSampleRate, 0.1),
  sentryRelease: `${androidPackage}@${version}`,
  sentryDist: String(Constants.expoConfig?.android?.versionCode ?? 1),
}

export const hasConfiguredExpoProject = (projectId: string | undefined): projectId is string => {
  return Boolean(projectId && projectId !== "REPLACE_WITH_EXPO_PROJECT_ID")
}

function normalizeOptionalString(value: string | undefined): string | undefined {
  const trimmed = value?.trim()
  return trimmed ? trimmed : undefined
}

function sampleRate(value: string | number | undefined, fallback: number): number {
  const parsed = typeof value === "number" ? value : Number(value)
  if (!Number.isFinite(parsed)) return fallback
  return Math.max(0, Math.min(parsed, 1))
}
