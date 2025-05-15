import { ChatParticipant } from "@in/protocol/core"
import type { DbChatParticipant } from "@in/server/db/schema"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { Log } from "@in/server/utils/log"

const log = new Log("encodeChatParticipant")

export function encodeChatParticipant(participant: DbChatParticipant): ChatParticipant {
  return {
    userId: BigInt(participant.userId),
    date: encodeDateStrict(participant.date),
  }
}
