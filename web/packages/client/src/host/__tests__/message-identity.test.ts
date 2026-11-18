import { chatId, messageId, userId } from "@inline/ids"
import { describe, expect, it } from "vitest"
import { DbObjectKind, messageKey, MessageSendingStatus, type Message } from "../../database/models"
import { MessageIdentity } from "../message-identity"

const local: Message = {
  kind: DbObjectKind.Message,
  id: messageKey(chatId(5), messageId(-1)),
  messageId: messageId(-1),
  randomId: 1234n,
  chatId: chatId(5),
  fromId: userId(7),
  message: "hi",
  out: true,
  date: 40,
  status: MessageSendingStatus.Sending,
}

const confirmed: Message = {
  ...local,
  id: messageKey(chatId(5), messageId(900)),
  messageId: messageId(900),
  randomId: undefined,
  status: MessageSendingStatus.Sent,
}

describe("MessageIdentity", () => {
  it("carries a client key across a server ID assignment it did not issue", () => {
    const identity = new MessageIdentity()
    identity.observe({ revision: 1, changes: [{ kind: DbObjectKind.Message, id: local.id, object: local }] })
    expect(identity.clientKeyFor(local)).toBe("1234")
    expect(identity.clientKeyFor(confirmed)).toBeUndefined()
    identity.observe({
      revision: 2,
      changes: [
        { kind: DbObjectKind.Message, id: local.id },
        { kind: DbObjectKind.Message, id: confirmed.id, object: confirmed },
      ],
    })
    expect(identity.clientKeyFor(confirmed)).toBe("1234")
  })

  it("does not adopt a different message that arrives in the same batch", () => {
    const identity = new MessageIdentity()
    identity.observe({ revision: 1, changes: [{ kind: DbObjectKind.Message, id: local.id, object: local }] })
    const other = { ...confirmed, message: "someone else" }
    identity.observe({
      revision: 2,
      changes: [
        { kind: DbObjectKind.Message, id: local.id },
        { kind: DbObjectKind.Message, id: other.id, object: other },
      ],
    })
    expect(identity.clientKeyFor(other)).toBeUndefined()
  })
})
