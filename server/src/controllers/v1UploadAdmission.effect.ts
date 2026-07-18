import {
  Context,
  type Effect,
  Layer,
  Semaphore,
} from "effect"

export interface V1UploadAdmissionShape {
  readonly withPermit: <A, E, R>(
    effect: Effect.Effect<A, E, R>,
  ) => Effect.Effect<A, E, R>
}

export class V1UploadAdmission extends Context.Service<
  V1UploadAdmission,
  V1UploadAdmissionShape
>()("@inline/server/v1/V1UploadAdmission") {}

export const MAX_CONCURRENT_V1_UPLOADS = 4

export const makeV1UploadAdmission = (
  concurrency = MAX_CONCURRENT_V1_UPLOADS,
): V1UploadAdmissionShape => {
  const semaphore =
    Semaphore.makeUnsafe(concurrency)
  return {
    withPermit:
      semaphore.withPermit,
  }
}

export const V1UploadAdmissionLive =
  Layer.succeed(
    V1UploadAdmission,
    makeV1UploadAdmission(),
  )
