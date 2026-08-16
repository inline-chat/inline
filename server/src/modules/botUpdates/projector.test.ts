import { describe, expect, test } from "bun:test"
import { MessageEntity_Type, type MessageEntities } from "@inline-chat/protocol/core"
import { activationReason, agentMentionTarget } from "./projector"

const entities = (userId?: number, agentId?: number): MessageEntities | undefined =>
  userId === undefined
    ? undefined
    : {
        entities: [{
          type: MessageEntity_Type.MENTION,
          offset: 0n,
          length: 1n,
          entity: {
            oneofKind: "mention",
            mention: {
              userId: BigInt(userId),
              ...(agentId === undefined ? {} : { agentId: BigInt(agentId) }),
            },
          },
        }],
      }

const reason = ({
  streamBotId = 20,
  authorId = 10,
  authorIsBot = true,
  messageEntities,
}: {
  streamBotId?: number
  authorId?: number
  authorIsBot?: boolean
  messageEntities?: MessageEntities
}) => activationReason({
  stream: { botUserId: streamBotId, messageTrigger: "all" },
  chat: { type: "thread" } as never,
  message: {
    fromId: authorId,
    from: { bot: authorIsBot },
    entities: messageEntities,
  } as never,
  reply: null,
})

describe("Bot update Agent activation", () => {
  test("keeps an undirected bot-authored message as context even for an all-message bot", () => {
    expect(reason({})).toBeUndefined()
  })

  test("activates a bot-authored message only through its explicit mention", () => {
    expect(reason({ messageEntities: entities(20, 73) })).toBe("mention")
    expect(reason({ messageEntities: entities(21, 73) })).toBeUndefined()
  })

  test("never wakes a bot from its own authored message", () => {
    expect(reason({ authorId: 20, messageEntities: entities(20, 73) })).toBeUndefined()
  })

  test("selects an Agent only under the paired bot user mention", () => {
    expect(agentMentionTarget(entities(20, 73), 20)).toBe(73)
    expect(agentMentionTarget(entities(21, 73), 20)).toBeUndefined()
  })
})
