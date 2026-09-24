import { Context, Effect, Layer } from "effect"
import { ErrorReporter } from "../../core/errors/errorReporter"
import {
  ProcessServiceStartFailure,
  ProcessServiceStopFailure,
  acquireDeferredOwnedProcess,
} from "../monitoring/ownedProcess.effect"
import type { NativeUploadWorker } from "./worker"

export interface NativeUploadProcessShape {
  readonly stop: Effect.Effect<void, ProcessServiceStopFailure>
  readonly start: Effect.Effect<NativeUploadWorker, ProcessServiceStartFailure>
}

export class NativeUploadProcess extends Context.Service<
  NativeUploadProcess,
  NativeUploadProcessShape
>()("@inline/server/uploads/NativeUploadProcess") {}

export interface NativeUploadProcessAdapter {
  readonly start: () => NativeUploadWorker | Promise<NativeUploadWorker>
  readonly stop: (worker: NativeUploadWorker) => void | Promise<void>
}

export interface LegacyNativeUploadModule {
  readonly acquireNativeUploadWorker: () => {
    readonly worker: NativeUploadWorker
    readonly release: () => Promise<void>
  }
}

export type LoadLegacyNativeUpload = () => Promise<LegacyNativeUploadModule>

const loadLegacyNativeUpload: LoadLegacyNativeUpload = () => import("./operations")

export const makeCurrentNativeUploadAdapter = (
  loadModule: LoadLegacyNativeUpload = loadLegacyNativeUpload,
): NativeUploadProcessAdapter => {
  let release: (() => Promise<void>) | undefined
  return {
    start: async () => {
      const module = await loadModule()
      const lease = module.acquireNativeUploadWorker()
      release = lease.release
      return lease.worker
    },
    stop: async () => {
      const ownedRelease = release
      release = undefined
      await ownedRelease?.()
    },
  }
}

export const makeNativeUploadProcessLayer = (
  adapter: NativeUploadProcessAdapter = makeCurrentNativeUploadAdapter(),
): Layer.Layer<NativeUploadProcess, ProcessServiceStartFailure, ErrorReporter> =>
  Layer.effect(
    NativeUploadProcess,
    acquireDeferredOwnedProcess({
      name: "native-upload",
      start: adapter.start,
      stop: adapter.stop,
    }),
  )

export const NativeUploadProcessLive = makeNativeUploadProcessLayer()
