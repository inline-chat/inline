import { Optional, type Static, Type } from "@sinclair/typebox"
import type { HandlerContext } from "@in/server/controllers/v1/helpers"
import APN from "apn"
import { getChatIdFromPeer } from "./sendMessage"
import { TInputPeerInfo } from "../models"
import { InlineError } from "../types/errors"
import { sessions } from "../db/schema"
import { eq } from "drizzle-orm"
import { db } from "../db"

export const Input = Type.Object({
  applePushToken: Type.String(),
})

export const Response = Type.Undefined()

export const handler = async (
  input: Static<typeof Input>,
  context: HandlerContext,
): Promise<Static<typeof Response>> => {
  console.log("sessionId", context.currentSessionId, input.applePushToken)
  await db
    .update(sessions)
    .set({ applePushToken: input.applePushToken })
    .where(eq(sessions.id, context.currentSessionId))
  console.log(`saved push notification for user   ${input.applePushToken}`)
  return undefined
}
