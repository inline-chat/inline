import {
  Context,
  Effect,
  Layer,
} from "effect"
import {
  ErrorReporter,
} from "../../core/errors/errorReporter"
import {
  ProcessServiceStartFailure,
  ProcessServiceStopFailure,
  acquireDeferredOwnedProcess,
} from "../monitoring/ownedProcess.effect"
import type {
  BlockContentImageWorker,
} from "./blockContentImageWorker"

export interface BlockContentImageProcessShape {
  readonly stop: Effect.Effect<void, ProcessServiceStopFailure>
  readonly start: Effect.Effect<
    BlockContentImageWorker | null,
    ProcessServiceStartFailure
  >
}

export class BlockContentImageProcess extends Context.Service<
  BlockContentImageProcess,
  BlockContentImageProcessShape
>()(
  "@inline/server/message/BlockContentImageProcess",
) {}

export interface BlockContentImageProcessAdapter {
  readonly start: () =>
    | BlockContentImageWorker
    | null
    | Promise<
      BlockContentImageWorker | null
    >
  readonly stop: (
    worker:
      | BlockContentImageWorker
      | null,
  ) => void | Promise<void>
}

export interface LegacyBlockContentImageModule {
  readonly startBlockContentImageWorker:
    () =>
      | BlockContentImageWorker
      | null
  readonly stopBlockContentImageWorker: (
    worker?:
      | BlockContentImageWorker
      | null,
  ) => Promise<void>
}

export type LoadLegacyBlockContentImage =
  () => Promise<
    LegacyBlockContentImageModule
  >

const loadLegacyBlockContentImage:
  LoadLegacyBlockContentImage =
  () => import("./blockContentImageWorker")

export const makeCurrentBlockContentImageAdapter =
  (
    loadModule:
      LoadLegacyBlockContentImage =
      loadLegacyBlockContentImage,
  ): BlockContentImageProcessAdapter => ({
    start: async () => {
      const legacy = await loadModule()
      return legacy
        .startBlockContentImageWorker()
    },
    stop: async (worker) => {
      const legacy = await loadModule()
      await legacy
        .stopBlockContentImageWorker(
          worker,
        )
    },
  })

const CurrentBlockContentImage =
  makeCurrentBlockContentImageAdapter()

export const makeBlockContentImageProcessLayer =
  (
    adapter:
      BlockContentImageProcessAdapter =
      CurrentBlockContentImage,
  ): Layer.Layer<
    BlockContentImageProcess,
    ProcessServiceStartFailure,
    ErrorReporter
  > =>
  Layer.effect(
    BlockContentImageProcess,
    acquireDeferredOwnedProcess({
      name: "block-content-image",
      start: adapter.start,
      stop: adapter.stop,
    }),
  )

export const BlockContentImageProcessLive =
  makeBlockContentImageProcessLayer()
