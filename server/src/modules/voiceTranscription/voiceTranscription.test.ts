import { describe, expect, mock, test } from "bun:test"
import type { InputPeer } from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import { FileModel } from "@in/server/db/models/files"
import { MessageModel } from "@in/server/db/models/messages"
import { files, messages, users, voices } from "@in/server/db/schema"
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

  test("passes work chat context prompt to the transcriber", async () => {
    const scenario = await createVoiceMessage("voice-transcribe-context", {
      userProfile: {
        firstName: "Mo",
        lastName: "Inline",
        username: "mo",
      },
    })

    const transcribeVoice = mock().mockResolvedValue("ship the branch")

    const result = await transcribeAndEditVoiceMessage(scenario, {
      transcribeVoice,
      editText: editMessage,
    })

    expect(result.didEdit).toBe(true)
    expect(transcribeVoice).toHaveBeenCalledTimes(1)

    const options = transcribeVoice.mock.calls[0]?.[1]
    expect(options?.prompt).toContain("Inline, a work chat app")
    expect(options?.prompt).toContain("Message kind: voice message")
    expect(options?.prompt).toContain("Chat type: direct message")
    expect(options?.prompt).toContain("Voice sender: Mo Inline (@mo)")
    expect(options?.prompt).toContain("Participant/name hints: Mo Inline (@mo)")
  })

  test("uses the base prompt when prompt context fails", async () => {
    const scenario = await createVoiceMessage("voice-transcribe-context-fallback")
    const transcribeVoice = mock().mockResolvedValue("fallback transcript")
    const buildPrompt = mock().mockRejectedValue(new Error("cache unavailable"))

    const result = await transcribeAndEditVoiceMessage(scenario, {
      transcribeVoice,
      editText: editMessage,
      buildPrompt,
    })

    expect(result.didEdit).toBe(true)
    expect(buildPrompt).toHaveBeenCalledTimes(1)

    const options = transcribeVoice.mock.calls[0]?.[1]
    expect(options?.prompt).toContain("Inline, a work chat app")
    expect(options?.prompt).toContain("Message kind: voice message")
    expect(options?.prompt).not.toContain("Voice sender:")
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

  test("propagates transcriber failures for scheduler error capture", async () => {
    const scenario = await createVoiceMessage("voice-transcribe-fails")
    const error = new Error("provider unavailable")
    const transcribeVoice = mock().mockRejectedValue(error)

    await expect(
      transcribeAndEditVoiceMessage(scenario, {
        transcribeVoice,
        editText: editMessage,
      }),
    ).rejects.toThrow("provider unavailable")

    const fullMessage = await MessageModel.getMessage(scenario.message.messageId, scenario.message.chatId)
    expect(fullMessage.text).toBeNull()
  })
})

async function createVoiceMessage(
  label: string,
  options: {
    userProfile?: Partial<typeof users.$inferInsert>
  } = {},
) {
  const user = await testUtils.createUser(nextEmail(label))
  if (options.userProfile) {
    await db.update(users).set(options.userProfile).where(eq(users.id, user.id))
  }
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
