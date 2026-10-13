import { describe, expect, it } from "@effect/vitest"
import * as BunFileSystem from "@effect/platform-bun/BunFileSystem"
import * as BunPath from "@effect/platform-bun/BunPath"
import { Deferred, Effect, Fiber, Stream } from "effect"
import { TestClock } from "effect/testing"
import { HttpServerRequest } from "effect/unstable/http"
import { defaultV1UploadLimits, parseV1UploadRequest } from "./v1UploadRequest.effect"
import { INLINE_MEDIA_UPLOAD_MAX_BYTES } from "@inline-chat/protocol/transfers"

const boundary = "inline-upload-watchdog"
const encode = (value: string) => new TextEncoder().encode(value)
const prefix = encode(`--${boundary}\r\nContent-Disposition: form-data; name="type"\r\n\r\nvideo\r\n` +
  `--${boundary}\r\nContent-Disposition: form-data; name="file"; filename="proof.mp4"\r\nContent-Type: video/mp4\r\n\r\n`)
const suffix = encode(`\r\n--${boundary}--\r\n`)

const requestWithStream = (stream: Stream.Stream<Uint8Array>) => {
  const request = HttpServerRequest.fromWeb(new Request("http://inline.test/v1/uploadFile", {
    method: "POST", headers: { "content-type": `multipart/form-data; boundary=${boundary}` },
  }))
  Object.defineProperty(request, "stream", { value: stream })
  return request
}
const provideFilesystem = Effect.provide([BunFileSystem.layer, BunPath.layer])

describe("legacy upload progress watchdog", () => {
  it("shares the 500 MB video/document limits and whole multipart cap", () => {
    expect(defaultV1UploadLimits.maxFileSize).toBe(INLINE_MEDIA_UPLOAD_MAX_BYTES.video)
    expect(defaultV1UploadLimits.maxFileSize).toBe(INLINE_MEDIA_UPLOAD_MAX_BYTES.document)
    expect(defaultV1UploadLimits.maxTotalSize).toBe(541_000_000)
  })

  it.effect("fails a stalled body with a typed408 and cancels its input", () => Effect.gen(function* () {
    let stopped = false
    const awaitingBytes = yield* Deferred.make<void>()
    const stream = Stream.concat(Stream.succeed(prefix), Stream.never.pipe(
      Stream.onStart(Deferred.succeed(awaitingBytes, undefined)),
    )).pipe(
      Stream.ensuring(Effect.sync(() => { stopped = true })),
    )
    const fiber = yield* Effect.scoped(Effect.flip(parseV1UploadRequest(requestWithStream(stream))))
      .pipe(provideFilesystem, Effect.forkChild)
    yield* Deferred.await(awaitingBytes)
    yield* TestClock.adjust("60 seconds")
    const error = yield* Fiber.join(fiber)
    expect(error).toMatchObject({ _tag: "V1MessagingProvidersPublicError", error: "REQUEST_TIMEOUT", errorCode: 408 })
    expect(stopped).toBe(true)
  }))

  it.effect("allows a progressing upload longer than its idle deadline", () => Effect.gen(function* () {
    const chunks = [prefix, encode("abc"), encode("def"), suffix]
    const awaitingChunks = yield* Effect.forEach(chunks, () => Deferred.make<void>())
    let index = 0
    const stream = Stream.fromIterable(chunks).pipe(
      Stream.mapEffect((chunk) => Deferred.succeed(awaitingChunks[index++]!, undefined).pipe(
        Effect.andThen(Effect.sleep("9 seconds")), Effect.as(chunk),
      )),
    )
    const fiber = yield* Effect.scoped(Effect.gen(function* () {
      const input = yield* parseV1UploadRequest(requestWithStream(stream), { ...defaultV1UploadLimits, idleTimeoutMs: 10_000 })
      expect(input["type"]).toBe("video")
      expect((input["file"] as File).size).toBe(6)
    })).pipe(provideFilesystem, Effect.forkChild)
    for (const awaitingChunk of awaitingChunks) {
      yield* Deferred.await(awaitingChunk)
      yield* TestClock.adjust("9 seconds")
    }
    yield* Fiber.join(fiber)
  }))
})
