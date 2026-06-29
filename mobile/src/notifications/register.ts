import Constants from "expo-constants"
import * as Device from "expo-device"
import * as Notifications from "expo-notifications"
import { Platform } from "react-native"

import { appConfig, hasConfiguredExpoProject } from "@/config/app"
import { createLogger } from "@/observability/logger"
import { RealtimeClient } from "@/realtime/client"

export type PushRegistrationState =
  | { status: "registered"; token: string }
  | { status: "skipped"; reason: string; action?: "open_settings" | "configure_project" | "physical_device" }
  | { status: "failed"; reason: string }

const log = createLogger("push.registration")

Notifications.setNotificationHandler({
  handleNotification: async () => ({
    shouldShowAlert: true,
    shouldPlaySound: true,
    shouldSetBadge: false,
    shouldShowBanner: true,
    shouldShowList: true,
  }),
})

export async function registerForInlinePush(token: string): Promise<PushRegistrationState> {
  if (Platform.OS !== "android") {
    return { status: "skipped", reason: "Android-only app build" }
  }

  if (!Device.isDevice) {
    log.info("Skipped push registration on non-device runtime")
    return {
      status: "skipped",
      reason: "Push registration requires a physical Android device",
      action: "physical_device",
    }
  }

  if (!hasConfiguredExpoProject(appConfig.projectId)) {
    log.warn("Skipped push registration because Expo project ID is missing")
    return { status: "skipped", reason: "Missing Expo project ID", action: "configure_project" }
  }

  try {
    await configureAndroidChannels()

    const permission = await ensurePermission()
    if (!permission.granted) {
      log.warn("Notification permission not granted", { status: permission.status, canAskAgain: permission.canAskAgain })
      return {
        status: "skipped",
        reason: "Notification permission not granted",
        action: permission.canAskAgain ? undefined : "open_settings",
      }
    }

    const result = await Notifications.getExpoPushTokenAsync({
      projectId: appConfig.projectId,
      applicationId: Constants.expoConfig?.android?.package,
    })

    const client = new RealtimeClient(token)
    try {
      await client.updateAndroidPushToken(result.data)
    } finally {
      client.close()
    }

    log.info("Registered Expo Android push token")
    return { status: "registered", token: result.data }
  } catch (error) {
    log.error("Push registration failed", error)
    return {
      status: "failed",
      reason: error instanceof Error ? error.message : "Push registration failed",
    }
  }
}

async function ensurePermission(): Promise<Notifications.PermissionResponse> {
  const existing = await Notifications.getPermissionsAsync()
  if (existing.granted) return existing

  const requested = await Notifications.requestPermissionsAsync()
  return requested
}

async function configureAndroidChannels() {
  await Notifications.setNotificationChannelAsync("messages", {
    name: "Messages",
    importance: Notifications.AndroidImportance.HIGH,
    vibrationPattern: [0, 160, 80, 160],
    lightColor: "#4f46e5",
  })

  await Notifications.setNotificationChannelAsync("messages_silent", {
    name: "Silent messages",
    importance: Notifications.AndroidImportance.DEFAULT,
    vibrationPattern: [],
    lightColor: "#4f46e5",
  })

  await Notifications.setNotificationChannelAsync("urgent", {
    name: "Urgent nudges",
    importance: Notifications.AndroidImportance.MAX,
    vibrationPattern: [0, 180, 80, 220],
    lightColor: "#dc2626",
  })
  log.debug("Configured Android notification channels")
}
