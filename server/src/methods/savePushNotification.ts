import { Optional, type Static, Type } from "@sinclair/typebox"
import type { HandlerContext } from "@in/server/controllers/v1/helpers"
import APN from "apn"
import { getChatIdFromPeer } from "./sendMessage"
import { TInputPeerInfo } from "../models"
import { InlineError } from "../types/errors"

export const Input = Type.Object({
  token: Type.String(),
  peerId: Optional(TInputPeerInfo),
  peerUserId: Optional(Type.String()),
  peerThreadId: Optional(Type.String()),
  title: Type.String(),
  body: Type.String(),
})

export const Response = Type.Undefined()

export const handler = async (
  input: Static<typeof Input>,
  context: HandlerContext,
): Promise<Static<typeof Response>> => {
  const APN_KEY = process.env["APN_KEY"]!
  const APN_KEY_ID = process.env["APN_KEY_ID"]!
  const APPLE_TEAM_ID = process.env["APPLE_TEAM_ID"]!

  if (!APN_KEY || !APN_KEY_ID || !APPLE_TEAM_ID) {
    throw new Error("APN credentials are not set")
  }
  const apn = new APN.Provider({
    token: {
      keyId: APN_KEY_ID,
      teamId: APPLE_TEAM_ID,
      key: Buffer.from(APN_KEY, "base64").toString(),
    },
  })

  if (!apn) {
    console.log("Failed to create APN provider", apn)
    throw new Error("Failed to create APN provider")
  }

  const notification = new APN.Notification({
    alert: input.title,
    body: input.body,
    badge: 1,
    sound: "default",
  })

  const peerId = input.peerUserId
    ? { userId: Number(input.peerUserId) }
    : input.peerThreadId
    ? { threadId: Number(input.peerThreadId) }
    : input.peerId

  if (!peerId) {
    throw new InlineError(InlineError.ApiError.PEER_INVALID)
  }

  const chatId = await getChatIdFromPeer(peerId, context)

  notification.payload = {
    chatId: chatId,
  }

  await apn.send(notification, input.token)

  return undefined
}
