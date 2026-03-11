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

  test("rejects non-ogg mime types", async () => {
    const file = new File([Uint8Array.from([1, 2, 3])], "voice.m4a", {
      type: "audio/mp4",
    })

    await expect(getVoiceMetadataAndValidate(file, 5, Uint8Array.from([1]))).rejects.toMatchObject({
      description: "Voice upload requires .ogg or .oga extension",
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
