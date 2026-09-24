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

export interface UserSettingsCleanupHandle {
  readonly stop: () => void | Promise<void>
}

export interface UserSettingsCleanupProcessShape {
  readonly stop: Effect.Effect<void, ProcessServiceStopFailure>
  readonly start: Effect.Effect<UserSettingsCleanupHandle, ProcessServiceStartFailure>
}

export class UserSettingsCleanupProcess extends Context.Service<
  UserSettingsCleanupProcess,
  UserSettingsCleanupProcessShape
>()(
  "@inline/server/cache/UserSettingsCleanupProcess",
) {}

export interface UserSettingsCleanupProcessAdapter {
  readonly start: () =>
    | UserSettingsCleanupHandle
    | Promise<UserSettingsCleanupHandle>
}

export interface LegacyUserSettingsCleanupModule {
  readonly startUserSettingsCacheCleanup:
    () => void
  readonly stopUserSettingsCacheCleanup:
    () => void
}

export type LoadLegacyUserSettingsCleanup =
  () => Promise<LegacyUserSettingsCleanupModule>

const loadLegacyUserSettingsCleanup: LoadLegacyUserSettingsCleanup =
  () => import("./userSettings")

export const makeCurrentUserSettingsCleanupAdapter =
  (
    loadModule: LoadLegacyUserSettingsCleanup =
      loadLegacyUserSettingsCleanup,
  ): UserSettingsCleanupProcessAdapter => ({
    start: async () => {
      const cleanup = await loadModule()
      cleanup.startUserSettingsCacheCleanup()
      return {
        stop:
          cleanup.stopUserSettingsCacheCleanup,
      }
    },
  })

const CurrentUserSettingsCleanup =
  makeCurrentUserSettingsCleanupAdapter()

export const makeUserSettingsCleanupProcessLayer = (
  adapter: UserSettingsCleanupProcessAdapter =
    CurrentUserSettingsCleanup,
): Layer.Layer<
  UserSettingsCleanupProcess,
  ProcessServiceStartFailure,
  ErrorReporter
> =>
  Layer.effect(
    UserSettingsCleanupProcess,
    acquireDeferredOwnedProcess({
      name: "user-settings-cache-cleanup",
      start: adapter.start,
      stop: (handle) => handle.stop(),
    }),
  )

/**
 * Scoped owner for the cleanup loop. The process host starts it after admission
 * dependencies are ready; ordinary module imports do not start a timer.
 */
export const UserSettingsCleanupProcessLive =
  makeUserSettingsCleanupProcessLayer()
