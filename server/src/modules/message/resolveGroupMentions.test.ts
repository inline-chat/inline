import { describe, expect, mock, test } from "bun:test"
import { MessageEntity_Type as T, type MessageEntities, type MessageEntity } from "@inline-chat/protocol/core"
import type { DbChat } from "@in/server/db/schema"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { resolveGroupMentions, validateGroupMentions } from "./resolveGroupMentions"
import { processOutgoingText } from "./processOutgoingText"

const chat = { id: 10, spaceId: 20 } as DbChat
const link = (url: string, offset = 3n, length = 4n): MessageEntity => ({
  type: T.TEXT_URL, offset, length, entity: { oneofKind: "textUrl", textUrl: { url } },
})
const group = (groupId = 44n, offset = 3n, length = 4n): MessageEntity => ({
  type: T.GROUP_MENTION, offset, length, entity: { oneofKind: "groupMention", groupMention: { groupId } },
})

describe("authorized group-mention resolution", () => {
  test("generic Markdown/import projection preserves the URL until an authorized message boundary", async () => {
    const result = await processOutgoingText({ text: "😀 [team](inline://group/44)", entities: undefined, parseMarkdown: true })
    expect(result.text).toBe("😀 team")
    expect(result.entities?.entities).toEqual([link("inline://group/44")])
    const literal = await processOutgoingText({ text: "[team](inline://group/44)", entities: undefined, parseMarkdown: false })
    expect(literal.text).toBe("[team](inline://group/44)")
    expect(literal.entities).toBeUndefined()
  })

  test("checks distinct group ids in the current actor/chat scope before returning converted entities", async () => {
    const entities = { entities: [link("inline://group/44"), group()] }, before = structuredClone(entities)
    const resolve = mock(async () => [8, 9])
    const output = await resolveGroupMentions({ text: "😀 team", entities, chat, currentUserId: 7 }, resolve)
    expect(resolve).toHaveBeenCalledTimes(1)
    expect(resolve).toHaveBeenCalledWith({ chat, currentUserId: 7, groupIds: [44] })
    expect(output).toEqual({ entities: { entities: [group()] }, mentionedUserIds: [8, 9] })
    expect(entities).toEqual(before)
  })

  test("edit validation authorizes groups without expanding their recipients", async () => {
    const entities = { entities: [link("inline://group/44"), group()] }
    const validate = mock(async () => undefined)
    const output = await validateGroupMentions({ text: "😀 team", entities, chat, currentUserId: 7 }, validate)
    expect(validate).toHaveBeenCalledTimes(1)
    expect(validate).toHaveBeenCalledWith({ chat, currentUserId: 7, groupIds: [44] })
    expect(output).toEqual({ entities: [group()] })
  })

  test("conflicting group identities on the same visible range fail closed", async () => {
    const resolve = mock(async () => [8])
    await expect(resolveGroupMentions({
      text: "😀 team", entities: { entities: [group(44n), group(45n)] }, chat, currentUserId: 7,
    }, resolve)).rejects.toMatchObject({ code: RealtimeRpcError.Code.BAD_REQUEST })
    expect(resolve).not.toHaveBeenCalled()
  })

  test("permission failures propagate without mutating the source or returning a resolved target", async () => {
    const entities = { entities: [link("inline://group/44")] }, before = structuredClone(entities)
    const denied = RealtimeRpcError.PeerIdInvalid()
    const resolve = mock(async () => { throw denied })
    await expect(resolveGroupMentions({ text: "😀 team", entities, chat, currentUserId: 7 }, resolve)).rejects.toBe(denied)
    expect(entities).toEqual(before)
    expect(resolve).toHaveBeenCalledTimes(1)
  })

  test("already explicit group entities use the same guard without rebuilding their payload", async () => {
    const entities = { entities: [group()] }
    const resolve = mock(async () => [])
    const output = await resolveGroupMentions({ text: "😀 team", entities, chat, currentUserId: 7 }, resolve)
    expect(output.entities).toBe(entities)
    expect(resolve).toHaveBeenCalledWith({ chat, currentUserId: 7, groupIds: [44] })
  })

  test("ordinary text, bare names and malformed URLs cause no group lookup", async () => {
    const resolve = mock(async () => [])
    for (const entities of [undefined, { entities: [] }, { entities: [link("https://e.test")] },
      { entities: [link("inline://group/0"), link("inline://group/44?agent_id=1")] }] satisfies (MessageEntities | undefined)[]) {
      const output = await resolveGroupMentions({ text: "😀 @eng", entities, chat, currentUserId: 7 }, resolve)
      expect(output.entities).toBe(entities)
      expect(output.mentionedUserIds).toEqual([])
    }
    expect(resolve).not.toHaveBeenCalled()
  })

  test("malformed ranges and unsafe database ids cannot reach the authority query", async () => {
    const resolve = mock(async () => [])
    for (const entity of [group(0n), group(-1n), group(2_147_483_648n), group(9_007_199_254_740_992n),
      link("inline://group/2147483648"),
      link("inline://group/9223372036854775807"), group(44n, 1n, 1n), group(44n, -1n),
      group(44n, 3n, 0n), group(44n, 3n, 100n), { ...group(), entity: { oneofKind: undefined } } satisfies MessageEntity]) {
      await expect(resolveGroupMentions({ text: "😀 team", entities: { entities: [entity] }, chat, currentUserId: 7 }, resolve)).rejects.toBeInstanceOf(RealtimeRpcError)
    }
    expect(resolve).not.toHaveBeenCalled()
  })
})
