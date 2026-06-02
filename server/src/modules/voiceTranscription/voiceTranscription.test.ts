import { describe, expect, mock, test } from "bun:test"
import type { InputPeer } from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import { FileModel } from "@in/server/db/models/files"
import { MessageModel } from "@in/server/db/models/messages"
import { files, messages, voices } from "@in/server/db/schema"
import { editMessage } from "@in/server/functions/messages.editMessage"
import { sendMessage } from "@in/server/functions/messages.sendMessage"
import { transcribeAndEditVoiceMessage } from "@in/server/modules/voiceTranscription"
import { setupTestLifecycle, testUtils } from "../../__tests__/setup"
import { and, eq } from "drizzle-orm"

const runId = Date.now()
let userIndex = 0
const nextEmail = (label: string) => `${label}-${runId}-${userIndex++}@example.com`

describe("voice transcription", () => {
  setupTestLifecycle()

  test("edits an unchanged blank voice message with the transcript", async () => {
    const scenario = await createVoiceMessage("voice-transcribe-apply")
    const transcribeVoice = mock().mockResolvedValue("hello from voice")

    const result = await transcribeAndEditVoiceMessage(scenario, {
      transcribeVoice,
      editText: editMessage,
    })

    expect(result.didEdit).toBe(true)
    expect(transcribeVoice).toHaveBeenCalledTimes(1)

    const fullMessage = await MessageModel.getMessage(scenario.message.messageId, scenario.message.chatId)
    expect(fullMessage.text).toBe("hello from voice")
    expect(fullMessage.voice?.id).toBe(scenario.voice.id)
  })

  test("does not edit when the message already changed", async () => {
    const scenario = await createVoiceMessage("voice-transcribe-skip")
    const transcribeVoice = mock().mockResolvedValue("late transcript")

    await editMessage(
      {
        messageId: BigInt(scenario.message.messageId),
        peer: scenario.inputPeer,
        text: "manual edit",
      },
      scenario.context,
    )

    const result = await transcribeAndEditVoiceMessage(scenario, {
      transcribeVoice,
      editText: editMessage,
    })

    expect(result.didEdit).toBe(false)
    expect(transcribeVoice).toHaveBeenCalledTimes(0)

    const fullMessage = await MessageModel.getMessage(scenario.message.messageId, scenario.message.chatId)
    expect(fullMessage.text).toBe("manual edit")
  })
})

async function createVoiceMessage(label: string) {
  const user = await testUtils.createUser(nextEmail(label))
  const chat = await testUtils.createPrivateChat(user, user)
  if (!chat) {
    throw new Error("Failed to create private chat")
  }

  const inputPeer: InputPeer = {
    type: { oneofKind: "chat", chat: { chatId: BigInt(chat.id) } },
  }
  const context = testUtils.functionContext({ userId: user.id, sessionId: 1 })
  const voice = await createVoiceForUser(user.id)

  const sent = await sendMessage(
    {
      peerId: inputPeer,
      voiceId: BigInt(voice.id),
    },
    context,
  )
  const sentMessageId = sent.updates[0]?.update.oneofKind === "updateMessageId"
    ? sent.updates[0].update.updateMessageId?.messageId
    : undefined

  if (!sentMessageId) {
    throw new Error("Failed to send voice message")
  }

  const message = await db._query.messages.findFirst({
    where: and(eq(messages.chatId, chat.id), eq(messages.messageId, Number(sentMessageId))),
  })
  if (!message) {
    throw new Error("Failed to fetch sent message")
  }

  const fullVoice = await FileModel.getVoiceById(BigInt(voice.id))
  if (!fullVoice) {
    throw new Error("Failed to fetch full voice")
  }

  return {
    message,
    voice: fullVoice,
    inputPeer,
    context,
  }
}

async function createVoiceForUser(userId: number) {
  const [file] = await db
    .insert(files)
    .values({
      fileUniqueId: `TRANSCRIBE-VOICE-${runId}-${userIndex++}`,
      userId,
      fileType: "voice",
      mimeType: "audio/ogg",
      fileSize: 321,
    })
    .returning()

  if (!file) {
    throw new Error("Failed to create test voice file")
  }

  const [voice] = await db
    .insert(voices)
    .values({
      fileId: file.id,
      duration: 8,
      waveform: Buffer.from([1, 2, 3]),
    })
    .returning()

  if (!voice) {
    throw new Error("Failed to create test voice")
  }

  return voice
}
