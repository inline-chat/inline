import { Expo, type ExpoPushMessage, type ExpoPushTicket } from "expo-server-sdk"

let expo: Expo | undefined

export function getExpoPushClient(): Expo {
  expo ??= new Expo({ accessToken: process.env["EXPO_ACCESS_TOKEN"] })
  return expo
}

export function isExpoPushToken(token: string): boolean {
  return Expo.isExpoPushToken(token)
}

export type { ExpoPushMessage, ExpoPushTicket }
