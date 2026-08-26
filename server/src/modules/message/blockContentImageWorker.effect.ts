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
  acquireOwnedProcess,
} from "../monitoring/ownedProcess.effect"
import type {
  BlockContentImageWorker,
} from "./blockContentImageWorker"

export interface BlockContentImageProcessShape {
  readonly worker:
    | BlockContentImageWorker
    | null
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
    acquireOwnedProcess({
      name: "block-content-image",
      start: adapter.start,
      stop: adapter.stop,
    }).pipe(
      Effect.map((worker) => ({ worker })),
    ),
  )

export const BlockContentImageProcessLive =
  makeBlockContentImageProcessLayer()
