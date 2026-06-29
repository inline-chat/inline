import type { ExpoConfig } from "expo/config"

const projectId = process.env.EXPO_PROJECT_ID ?? "REPLACE_WITH_EXPO_PROJECT_ID"
const apiBaseUrl = process.env.EXPO_PUBLIC_INLINE_API_BASE_URL ?? "https://api.inline.chat"
const apiWsUrl = process.env.EXPO_PUBLIC_INLINE_API_WS_URL ?? "wss://api.inline.chat/realtime"
const updateUrl = process.env.EXPO_UPDATE_URL ?? `https://u.expo.dev/${projectId}`
const appEnv = process.env.EXPO_PUBLIC_APP_ENV ?? process.env.APP_ENV ?? "production"
const sentryTracesSampleRate = process.env.EXPO_PUBLIC_SENTRY_TRACES_SAMPLE_RATE ?? "0.1"
const sentryUrl = process.env.SENTRY_URL ?? "https://sentry.io/"

const config: ExpoConfig = {
  name: "Inline",
  slug: "inline-mobile",
  owner: process.env.EXPO_OWNER,
  version: "0.1.0",
  orientation: "portrait",
  scheme: "inline",
  userInterfaceStyle: "automatic",
  icon: "./assets/icon.png",
  runtimeVersion: {
    policy: "appVersion",
  },
  updates: {
    enabled: true,
    fallbackToCacheTimeout: 0,
    url: updateUrl,
  },
  android: {
    package: process.env.EXPO_ANDROID_PACKAGE ?? "chat.inline.android",
    versionCode: Number(process.env.EXPO_ANDROID_VERSION_CODE ?? "1"),
    adaptiveIcon: {
      foregroundImage: "./assets/adaptive-icon.png",
      backgroundColor: "#0f172a",
    },
    permissions: ["POST_NOTIFICATIONS", "VIBRATE"],
  },
  plugins: [
    "expo-router",
    "expo-secure-store",
    [
      "expo-notifications",
      {
        icon: "./assets/notification-icon.png",
        color: "#4f46e5",
        defaultChannel: "messages",
      },
    ],
    [
      "@sentry/react-native/expo",
      {
        organization: process.env.SENTRY_ORG,
        project: process.env.SENTRY_PROJECT,
        url: sentryUrl,
      },
    ],
  ],
  extra: {
    apiBaseUrl,
    apiWsUrl,
    appEnv,
    sentryDsn: process.env.EXPO_PUBLIC_SENTRY_DSN,
    sentryTracesSampleRate,
    eas: {
      projectId,
    },
  },
}

export default config
