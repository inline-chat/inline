import { describe, expect, test } from "bun:test"
import { getVoiceMetadataAndValidate } from "@in/server/modules/files/metadata"

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

  test("rejects empty waveforms", async () => {
    const file = new File([Uint8Array.from([1, 2, 3])], "voice.ogg", {
      type: "audio/ogg",
    })

    await expect(getVoiceMetadataAndValidate(file, 5, new Uint8Array())).rejects.toMatchObject({
      description: "Voice upload requires a non-empty waveform",
    })
  })
})
