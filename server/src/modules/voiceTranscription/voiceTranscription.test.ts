import { describe, expect, mock, test } from "bun:test"
import type { InputPeer } from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import { FileModel } from "@in/server/db/models/files"
import { MessageModel } from "@in/server/db/models/messages"
import { files, messages, users, voices } from "@in/server/db/schema"
import { editMessage } from "@in/server/functions/messages.editMessage"
import { sendMessage } from "@in/server/functions/messages.sendMessage"
import { transcribeAndEditVoiceMessage } from "@in/server/modules/voiceTranscription"
import { buildGptTranscribeRequest, voiceTranscriptionModel } from "@in/server/modules/voiceTranscription/openAITranscriber"
import {
  buildVoiceTranscriptionContext,
  buildVoiceTranscriptionContextFromParts,
} from "@in/server/modules/voiceTranscription/prompt"
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

  test("passes work chat transcription context to the transcriber", async () => {
    const scenario = await createVoiceMessage("voice-transcribe-context")
    const prompt = [
      "A voice message recorded in Inline, a work chat app for teammates.",
      "- Message kind: voice message",
      "- Chat type: direct message",
      "- Voice sender: Mo Inline (@mo)",
    ].join("\n")
    const buildContext = mock().mockResolvedValue({
      prompt,
      keywords: ["Inline", "Mo Inline", "RealtimeV2"],
      languages: [],
      chatType: "private",
      participantCount: 1,
      includedParticipantCount: 1,
      recentTranscriptCount: 0,
      hasChatTitle: false,
      hasSpaceName: false,
    })
    const transcribeVoice = mock().mockResolvedValue("ship the branch")

    const result = await transcribeAndEditVoiceMessage(scenario, {
      transcribeVoice,
      editText: editMessage,
      buildContext,
    })

    expect(result.didEdit).toBe(true)
    expect(buildContext).toHaveBeenCalledTimes(1)
    expect(transcribeVoice).toHaveBeenCalledTimes(1)

    const options = transcribeVoice.mock.calls[0]?.[1]
    expect(options?.prompt).toBe(prompt)
    expect(options?.keywords).toEqual(["Inline", "Mo Inline", "RealtimeV2"])
    expect(options?.languages).toEqual([])
  })

  test("uses the base prompt when prompt context fails", async () => {
    const scenario = await createVoiceMessage("voice-transcribe-context-fallback")
    const transcribeVoice = mock().mockResolvedValue("fallback transcript")
    const buildContext = mock().mockRejectedValue(new Error("cache unavailable"))

    const result = await transcribeAndEditVoiceMessage(scenario, {
      transcribeVoice,
      editText: editMessage,
      buildContext,
    })

    expect(result.didEdit).toBe(true)
    expect(buildContext).toHaveBeenCalledTimes(1)

    const options = transcribeVoice.mock.calls[0]?.[1]
    expect(options?.prompt).toContain("Inline, a work chat app")
    expect(options?.prompt).toContain("Message kind: voice message")
    expect(options?.prompt).not.toContain("Voice sender:")
    expect(options?.keywords).toContain("Inline")
    expect(options?.languages).toEqual([])
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

  test("builds bounded keyword and earlier-turn context", () => {
    const context = buildVoiceTranscriptionContextFromParts({
      chatType: "thread",
      chatTitle: "Roadmap <Q3>\nlaunch",
      spaceName: "Inline Team",
      senderName: "Mo Inline (@mo)",
      participantKeywords: ["Mo\nInline", "Mo Inline", ...Array.from({ length: 80 }, (_, index) => `Term ${index}`)],
      participantCount: 82,
      includedParticipantCount: 24,
      recentTranscripts: [
        "old transcript 1",
        "old transcript 2",
        "old transcript 3",
        "old transcript 4",
        "latest transcript 5",
      ],
      voiceDurationSeconds: 12,
    })

    expect(context.prompt).toContain("A voice message recorded in Inline")
    expect(context.prompt).not.toContain("Return only the spoken words")
    expect(context.prompt).not.toContain("old transcript 1")
    expect(context.prompt).toContain("latest transcript 5")
    expect(context.keywords).toContain("Roadmap Q3 launch")
    expect(context.keywords).toContain("Mo Inline")
    expect(context.keywords.filter((keyword) => keyword === "Mo Inline")).toHaveLength(1)
    expect(context.keywords).toHaveLength(64)
    expect(context.languages).toEqual([])
    expect(context.recentTranscriptCount).toBe(4)
    expect(context.participantCount).toBe(82)
    expect(context.includedParticipantCount).toBe(24)
  })

  test("includes earlier voice-message transcripts from the same chat", async () => {
    const earlier = await createVoiceMessage("voice-transcribe-earlier-turn")
    await editMessage(
      {
        messageId: BigInt(earlier.message.messageId),
        peer: earlier.inputPeer,
        text: "Discuss the RealtimeV2 rollout with Arman tomorrow.",
        parseMarkdown: false,
      },
      earlier.context,
    )

    const nextVoice = await createVoiceForUser(earlier.user.id)
    const sent = await sendMessage(
      {
        peerId: earlier.inputPeer,
        voiceId: BigInt(nextVoice.id),
      },
      earlier.context,
    )
    const sentMessageId = sent.updates[0]?.update.oneofKind === "updateMessageId"
      ? sent.updates[0].update.updateMessageId?.messageId
      : undefined
    if (!sentMessageId) throw new Error("Failed to send follow-up voice message")

    const message = await db._query.messages.findFirst({
      where: and(eq(messages.chatId, earlier.chat.id), eq(messages.messageId, Number(sentMessageId))),
    })
    const voice = await FileModel.getVoiceById(BigInt(nextVoice.id))
    if (!message || !voice) throw new Error("Failed to load follow-up voice message")

    const context = await buildVoiceTranscriptionContext({ message, voice })

    expect(context.recentTranscriptCount).toBe(1)
    expect(context.prompt).toContain("Earlier voice-message transcripts in this chat")
    expect(context.prompt).toContain("Discuss the RealtimeV2 rollout with Arman tomorrow.")
  })

  test("builds the typed gpt-transcribe request", () => {
    const file = new File([new Uint8Array([1, 2, 3])], "voice.ogg", { type: "audio/ogg" })
    const built = buildGptTranscribeRequest(file, {
      prompt: "  Inline launch discussion  ",
      keywords: ["<Inline>", "Inline", "RealtimeV2\n"],
      languages: ["EN", "fa", "en"],
    })
    expect(built.request.model).toBe(voiceTranscriptionModel)
    expect(built.request.model).toBe("gpt-transcribe")
    expect(built.request.prompt).toBe("Inline launch discussion")
    expect(built.request.file).toBe(file)
    expect(built.request.keywords).toEqual(["Inline", "RealtimeV2"])
    expect(built.request.languages).toEqual(["en", "fa"])
    expect(built.context).toEqual({
      hasPrompt: true,
      promptLength: 24,
      keywordCount: 2,
      languageHintCount: 2,
    })
  })
})

async function createVoiceMessage(
  label: string,
  options: {
    userProfile?: Omit<Partial<typeof users.$inferInsert>, "email">
  } = {},
) {
  const user = await createVoiceTestUser(label, options.userProfile)
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
    user,
    chat,
    message,
    voice: fullVoice,
    inputPeer,
    context,
  }
}

async function createVoiceTestUser(label: string, userProfile: Omit<Partial<typeof users.$inferInsert>, "email"> = {}) {
  const [user] = await db
    .insert(users)
    .values({
      ...userProfile,
      email: nextEmail(label),
    })
    .returning()

  if (!user) {
    throw new Error("Failed to create test user")
  }

  return user
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
