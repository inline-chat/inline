import { describe, expect, test } from "bun:test"
import { SpeechSegmenter, type SpeechAction } from "./segmenter.js"

function frame(rate: number, id: number, milliseconds = 20): Int16Array {
  return new Int16Array(rate * milliseconds / 1000).fill(id)
}
function emittedFrames(actions: readonly SpeechAction[]): Int16Array[] {
  return actions.flatMap((action) => action.kind === "start" ? [...action.frames]
    : action.kind === "audio" ? [action.frame] : [])
}

describe("bounded speech segmentation", () => {
  for (const rate of [16_000, 24_000]) {
    test(`${rate}Hz silence retains only 300ms of pre-roll and threshold starts one turn`, () => {
      const segmenter = new SpeechSegmenter(rate)
      for (let id = 1; id <= 1000; id++) expect(segmenter.accept(frame(rate, id), 0.49)).toEqual([])
      const actions = segmenter.accept(frame(rate, 1001), 0.5)
      expect(actions.map((action) => action.kind)).toEqual(["start"])
      const audio = emittedFrames(actions)
      expect(audio.reduce((sum, value) => sum + value.length, 0)).toBe(rate * 0.3)
      expect(audio.map((value) => value[0])).toEqual(Array.from({ length: 15 }, (_, index) => 987 + index))
    })

    test(`${rate}Hz trailing silence ends at its frame boundary and speech resets the silence count`, () => {
      const segmenter = new SpeechSegmenter(rate)
      segmenter.accept(frame(rate, 1), 1)
      for (let id = 2; id <= 28; id++) expect(segmenter.accept(frame(rate, id), 0).map((action) => action.kind)).toEqual(["audio"])
      expect(segmenter.accept(frame(rate, 29), 1).map((action) => action.kind)).toEqual(["audio"])
      for (let id = 30; id <= 56; id++) expect(segmenter.accept(frame(rate, id), 0).map((action) => action.kind)).toEqual(["audio"])
      expect(segmenter.accept(frame(rate, 57), 0).map((action) => action.kind)).toEqual(["audio", "end"])
      expect(segmenter.accept(frame(rate, 58), 0)).toEqual([])
      expect(segmenter.stop()).toBe(false)
    })

    test(`${rate}Hz a soft turn waits for 200ms of silence`, () => {
      const segmenter = new SpeechSegmenter(rate)
      for (let id = 1; id <= 300; id++) expect(segmenter.accept(frame(rate, id), 1).some((action) => action.kind === "end")).toBe(false)
      for (let id = 301; id <= 309; id++) expect(segmenter.accept(frame(rate, id), 0).map((action) => action.kind)).toEqual(["audio"])
      expect(segmenter.accept(frame(rate, 310), 0).map((action) => action.kind)).toEqual(["audio", "end"])
    })

    test(`${rate}Hz continuous speech splits at 10 seconds with every captured frame emitted once`, () => {
      const segmenter = new SpeechSegmenter(rate)
      const ids: number[] = []
      const lengths: number[] = []
      let turnSamples = 0
      let starts = 0
      for (let id = 1; id <= 1100; id++) {
        const actions = segmenter.accept(frame(rate, id), 1)
        starts += actions.filter((action) => action.kind === "start").length
        for (const audio of emittedFrames(actions)) { ids.push(audio[0]!); turnSamples += audio.length }
        if (actions.some((action) => action.kind === "end")) { lengths.push(turnSamples); turnSamples = 0 }
      }
      expect(ids).toEqual(Array.from({ length: 1100 }, (_, index) => index + 1))
      expect(starts).toBe(3)
      expect(lengths).toEqual([rate * 10, rate * 10])
      expect(turnSamples).toBe(rate * 2)
      expect(segmenter.stop()).toBe(true)
      expect(segmenter.stop()).toBe(false)
      expect(() => segmenter.accept(frame(rate, 1101), 1)).toThrow("Grid transcription stopped")
    })

    test(`${rate}Hz variable frames overshoot the hard boundary by less than one bounded frame`, () => {
      const segmenter = new SpeechSegmenter(rate)
      let samples = 0
      let ended = false
      while (!ended) {
        const actions = segmenter.accept(new Int16Array(511), 1)
        samples += emittedFrames(actions).reduce((sum, value) => sum + value.length, 0)
        ended = actions.some((action) => action.kind === "end")
      }
      expect(samples).toBeGreaterThanOrEqual(rate * 10)
      expect(samples).toBeLessThan(rate * 10 + 511)
    })
  }

  test("pre-roll owns samples and settings cannot be changed after construction", () => {
    const settings = { prerollMs: 300, silenceMs: 550, softTurnMs: 6000, hardTurnMs: 10_000, threshold: 0.5 }
    const segmenter = new SpeechSegmenter(16_000, settings)
    const reusable = frame(16_000, 7)
    segmenter.accept(reusable, 0)
    reusable.fill(9)
    settings.threshold = 0
    expect(segmenter.accept(reusable, 0)).toEqual([])
    const audio = emittedFrames(segmenter.accept(frame(16_000, 11), 1))
    expect(audio.map((value) => value[0])).toEqual([7, 9, 11])
  })

  test("validates rates, setting bounds, frames and probabilities", () => {
    expect(() => new SpeechSegmenter(44_100)).toThrow("Grid transcription audio")
    const valid = { prerollMs: 300, silenceMs: 550, softTurnMs: 6000, hardTurnMs: 10_000, threshold: 0.5 }
    for (const settings of [{ ...valid, prerollMs: Infinity }, { ...valid, prerollMs: 301 },
      { ...valid, silenceMs: 0 }, { ...valid, softTurnMs: 10_001 }, { ...valid, hardTurnMs: 10_001 },
      { ...valid, threshold: -0.1 }, { ...valid, threshold: 1.1 }]) {
      expect(() => new SpeechSegmenter(16_000, settings)).toThrow("Grid transcription audio")
    }
    const segmenter = new SpeechSegmenter(16_000)
    for (const probability of [-1, 1.1, NaN, Infinity]) {
      expect(() => segmenter.accept(frame(16_000, 1), probability)).toThrow("Grid transcription audio")
    }
    expect(() => segmenter.accept(new Int16Array(), 0)).toThrow("Grid transcription audio")
    expect(() => segmenter.accept(new Int16Array(1601), 0)).toThrow("Grid transcription audio")
    expect(segmenter.stop()).toBe(false)
  })
})
