import * as Application from "expo-application"
import * as Device from "expo-device"
import { Platform } from "react-native"

import { postJson } from "@/api/client"
import { getDeviceId } from "@/auth/session"
import { appConfig } from "@/config/app"

export type InlineUser = {
  id: number | string
  firstName?: string
  lastName?: string
  username?: string
  email?: string
}

export type SendCodeResult = {
  existingUser: boolean
  needsInviteCode: boolean
  challengeToken?: string
}

export type VerifyCodeResult = {
  userId: number
  token: string
  user: InlineUser
}

export async function sendEmailCode(email: string): Promise<SendCodeResult> {
  const meta = await clientMeta()
  return postJson<SendCodeResult>("sendEmailCode", {
    email,
    ...meta,
  })
}

export async function verifyEmailCode(input: {
  email: string
  code: string
  challengeToken?: string
  inviteCode?: string
}): Promise<VerifyCodeResult> {
  const meta = await clientMeta()
  return postJson<VerifyCodeResult>("verifyEmailCode", {
    ...input,
    ...meta,
  })
}

async function clientMeta() {
  const timezone = Intl.DateTimeFormat().resolvedOptions().timeZone
  return {
    clientType: "android",
    clientVersion: normalizeSemver(appConfig.version),
    osVersion: normalizeSemver(String(Platform.Version)),
    deviceId: await getDeviceId(),
    deviceName: Device.deviceName ?? Application.applicationName ?? "Android device",
    timezone,
  }
}

function normalizeSemver(value: string): string {
  const parts = value.split(".").map((part) => part.replace(/[^0-9]/g, "") || "0")
  while (parts.length < 3) parts.push("0")
  return parts.slice(0, 4).join(".")
}
