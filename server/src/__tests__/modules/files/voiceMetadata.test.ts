import { describe, expect, test } from "bun:test"
import { getVoiceMetadataAndValidate } from "@in/server/modules/files/metadata"
import { resolveVoiceMimeType } from "@in/server/modules/files/voiceMime"

describe("getVoiceMetadataAndValidate", () => {
  test("accepts canonical ogg opus voice metadata", async () => {
    const file = new File([Uint8Array.from([1, 2, 3, 4])], "voice.ogg", {
      type: "audio/ogg",
    })

    const metadata = await getVoiceMetadataAndValidate(file, 7, Uint8Array.from([3, 2, 1]))

    expect(metadata.duration).toBe(7)
    expect(metadata.mimeType).toBe("audio/ogg")
    expect(metadata.extension).toBe("ogg")
    expect(metadata.waveform).toEqual(Uint8Array.from([3, 2, 1]))
  })

  test("accepts m4a voice metadata", async () => {
    const file = new File([Uint8Array.from([1, 2, 3])], "voice.m4a", {
      type: "audio/mp4",
    })

    const metadata = await getVoiceMetadataAndValidate(file, 5, Uint8Array.from([1]))

    expect(metadata.mimeType).toBe("audio/mp4")
    expect(metadata.extension).toBe("m4a")
  })

  test("accepts mp4 voice metadata", async () => {
    const file = new File([Uint8Array.from([1, 2, 3])], "voice.mp4", {
      type: "audio/x-m4a",
    })

    const metadata = await getVoiceMetadataAndValidate(file, 5, Uint8Array.from([1]))

    expect(metadata.mimeType).toBe("audio/x-m4a")
    expect(metadata.extension).toBe("mp4")
  })

  test("rejects unsupported voice types", async () => {
    const file = new File([Uint8Array.from([1, 2, 3])], "voice.wav", {
      type: "audio/wav",
    })

    await expect(getVoiceMetadataAndValidate(file, 5, Uint8Array.from([1]))).rejects.toMatchObject({
      description: "Voice upload requires .ogg, .oga, .m4a, or .mp4 extension",
    })
  })

  test("rejects voice MIME type and extension mismatches", async () => {
    const file = new File([Uint8Array.from([1, 2, 3])], "voice.ogg", {
      type: "audio/mp4",
    })

    await expect(getVoiceMetadataAndValidate(file, 5, Uint8Array.from([1]))).rejects.toMatchObject({
      description: "Voice upload MIME type does not match file extension",
    })
  })

  test("rejects unsupported upload MIME types even with a valid extension", async () => {
    const file = new File([Uint8Array.from([1, 2, 3])], "voice.ogg", {
      type: "application/octet-stream",
    })

    await expect(getVoiceMetadataAndValidate(file, 5, Uint8Array.from([1]))).rejects.toMatchObject({
      description: "Voice upload requires audio/ogg, audio/mp4, or audio/x-m4a MIME type",
    })
  })

  test("rejects empty waveforms", async () => {
    const file = new File([Uint8Array.from([1, 2, 3])], "voice.ogg", {
      type: "audio/ogg",
    })

    await expect(getVoiceMetadataAndValidate(file, 5, new Uint8Array())).rejects.toMatchObject({
      description: "Voice upload requires a non-empty waveform",
    })
  })
})

describe("resolveVoiceMimeType", () => {
  test("resolves old rows from a supported storage extension when MIME is missing", () => {
    const result = resolveVoiceMimeType({
      mimeType: null,
      path: "voices/abc123.m4a",
    })

    expect(result).toMatchObject({
      ok: true,
      mimeType: "audio/mp4",
      extension: "m4a",
    })
  })

  test("resolves old rows from a supported storage extension when MIME is invalid and fallback is allowed", () => {
    const result = resolveVoiceMimeType({
      mimeType: "application/octet-stream",
      path: "voices/abc123.m4a",
      allowExtensionFallbackForInvalidMime: true,
    })

    expect(result).toMatchObject({
      ok: true,
      mimeType: "audio/mp4",
      extension: "m4a",
    })
  })

  test("rejects old rows when MIME and storage extension disagree", () => {
    const result = resolveVoiceMimeType({
      mimeType: "audio/ogg",
      path: "voices/abc123.m4a",
    })

    expect(result).toMatchObject({
      ok: false,
      reason: "mismatch",
      mimeType: "audio/ogg",
      extension: "m4a",
    })
  })

  test("rejects old rows with no supported MIME or extension", () => {
    const result = resolveVoiceMimeType({
      mimeType: null,
      path: "voices/abc123.bin",
    })

    expect(result).toMatchObject({
      ok: false,
      reason: "unsupported-extension",
      extension: "bin",
    })
  })
})
