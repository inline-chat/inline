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

You're one of the very first users of Inline. Exciting to build the future of work chat with you! 

Things we'll be working on next (in no particular order):
- API to send messages 
- Faster image sending and loading
- Sending video 
- Managing private group chat participants
- Better representaion of spaces (supergroups) in the home UI 
- Sync for more events (eg. deleting messages)
- "Will Do" to create tasks in Notion via AI
- Magic translate via AI 
- Edit profile and photo on macOS 
- Edit message on macOS 
- Reactions on macOS 
- Translation for the app in Chinese 
- @mentions 

What we recently shipped:
- Group chats 
- Sign up via SMS 
- Invite via email, phone number, or username

Message to @mo or @dena if you hit a bug or need a feature.
`

    return text
  } catch (error) {
    Log.shared.error("Failed to get alpha text", error)
    throw new InlineError(InlineError.ApiError.INTERNAL)
  }
}
