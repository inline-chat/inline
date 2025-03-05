import type { HandlerContext } from "@in/server/controllers/helpers"
import { db } from "@in/server/db"
import { Log } from "@in/server/utils/log"
import { Type } from "@sinclair/typebox"
import type { Static } from "elysia"
import { encodeReactionInfo, TReactionInfo } from "../api-types"
import { reactions } from "../db/schema/reactions"
import { InlineError } from "../types/errors"
import { TInputId } from "../types/methods"

export const Input = Type.Object({
  // No input needed for this endpoint
})

export const Response = Type.String()

export const handler = async (
  input: Static<typeof Input>,
  context: HandlerContext,
): Promise<Static<typeof Response>> => {
  try {
    let text = `
**Welcome to Inline Alpha**

It's exciting to have you as the first few users here. This app is still in an incomplete state but we're aiming to ship new releases every day. Expect bugs and missing features. Please send us issues you see and things we should prioritize for you. Send a message to @mo or @dena here.

Things we're working on:
- Sending video and files
- Private chats 
- Inviting by phone number
- Showing local time in chat view
- @mention in chats
- Bug fixes
`

    return text
  } catch (error) {
    Log.shared.error("Failed to get alpha text", error)
    throw new InlineError(InlineError.ApiError.INTERNAL)
  }
}
