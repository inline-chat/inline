import { RpcError_Code, type TranscribeVoiceDraftInput, type TranscribeVoiceDraftResult } from "@inline-chat/protocol/core"
import { resolveVoiceMimeType } from "@in/server/modules/files/voiceMime"
import { InMemoryRateLimiter } from "@in/server/modules/oauth/rateLimiter"
import { transcribeAudioFileWithOpenAI } from "@in/server/modules/voiceTranscription/openAITranscriber"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import type { HandlerContext } from "@in/server/realtime/types"

const limiter = new InMemoryRateLimiter({ capacity: 10_000 })
const invalidRecording = () => new RealtimeRpcError(RpcError_Code.BAD_REQUEST, "This recording cannot be transcribed.", 400)

export async function transcribeVoiceDraft(
  input: TranscribeVoiceDraftInput,
  context: HandlerContext,
): Promise<TranscribeVoiceDraftResult> {
  if (!context.userId) throw RealtimeRpcError.Unauthenticated()
  const type = resolveVoiceMimeType({ mimeType: input.mimeType, allowExtensionFallbackForInvalidMime: false })
  if (!input.audio.length || input.audio.length > 4 * 1024 * 1024 ||
      !input.duration || input.duration > 600 || !type.ok) throw invalidRecording()
  const rate = limiter.consume({
    key: `voice-draft:${context.userId}`,
    nowMs: Date.now(),
    rule: { max: 6, windowMs: 60_000 },
  })
  if (!rate.allowed) throw RealtimeRpcError.RateLimit()

  // Stay below the carrier's 30-second deadline to return actionable copy.
  const timeout = AbortSignal.timeout(25_000)
  const signal = context.signal ? AbortSignal.any([context.signal, timeout]) : timeout
  let text: string | undefined
  try {
    signal.throwIfAborted()
    const extension = type.mimeType === "audio/ogg" ? "ogg" : "m4a"
    const file = new File([new Uint8Array(input.audio)], `dictation.${extension}`, { type: type.mimeType })
    text = (await transcribeAudioFileWithOpenAI(file, { signal }))?.trim()
  } catch {
    if (signal.aborted) {
      throw new RealtimeRpcError(RpcError_Code.INTERNAL_ERROR, "Transcription took too long. Try again or record a shorter dictation.", 500)
    }
    // Provider errors may contain request details; do not expose or log them.
    throw new RealtimeRpcError(RpcError_Code.INTERNAL_ERROR, "Could not transcribe this recording. Please try again.", 500)
  }
  if (!text) {
    throw new RealtimeRpcError(RpcError_Code.BAD_REQUEST, "No transcript was returned. Try again or record another dictation.", 400)
  }
  return { text }
}
