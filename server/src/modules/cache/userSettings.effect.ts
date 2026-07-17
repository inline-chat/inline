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

export interface UserSettingsCleanupHandle {
  readonly stop: () => void | Promise<void>
}

export interface UserSettingsCleanupProcessShape {
  readonly running: true
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
    acquireOwnedProcess({
      name: "user-settings-cache-cleanup",
      start: adapter.start,
      stop: (handle) => handle.stop(),
    }).pipe(
      Effect.as({
        running: true as const,
      }),
    ),
  )

/**
 * Compatibility owner for the legacy cleanup singleton. The user-settings
 * module still starts cleanup on its first import, which may happen before this
 * Layer acquires it through another production consumer.
 *
 * TODO(effect-cutover): remove the module-level auto-start only after the
 * replacement process graph is production-owned; then this Layer becomes the
 * sole startup and shutdown owner.
 */
export const UserSettingsCleanupProcessLive =
  makeUserSettingsCleanupProcessLayer()
