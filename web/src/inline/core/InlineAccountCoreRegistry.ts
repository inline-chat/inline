import type { UserID } from "@inline/ids"
import { authSession } from "../auth/auth-session-core"
import { InlineAccountCore } from "./InlineAccountCore"
import { inlineLog } from "../logging/InlineLogging"
import {
  createInlineCoreAccountOwnershipAcquirer,
  type InlineCoreLockManager,
} from "./InlineCoreAccountOwnership"

export type InlineAccountCoreOwner = {
  readonly accountId: UserID
  start: () => Promise<void>
  stop: () => Promise<void>
}

type RegistryEntry<Core extends InlineAccountCoreOwner> = {
  core: Core
  references: number
  stopTimer: ReturnType<typeof setTimeout> | null
}

export class InlineAccountCoreRegistry<
  Core extends InlineAccountCoreOwner,
> {
  private readonly entries = new Map<
    UserID,
    RegistryEntry<Core>
  >()

  constructor(
    private readonly createCore: (accountId: UserID) => Core,
  ) {}

  get(accountId: UserID): Core {
    const existing = this.entries.get(accountId)
    if (existing) return existing.core

    const core = this.createCore(accountId)
    this.entries.set(accountId, {
      core,
      references: 0,
      stopTimer: null,
    })
    return core
  }

  /**
   * Deferred teardown absorbs React Strict Mode's development-only effect
   * cleanup/remount cycle.
   */
  retain(core: Core) {
    const entry = this.entries.get(core.accountId)
    if (!entry || entry.core !== core) {
      throw new Error("Inline account core is not registered")
    }

    if (entry.stopTimer) {
      clearTimeout(entry.stopTimer)
      entry.stopTimer = null
    }
    entry.references += 1
    void core.start().catch(() => {
      // The account core publishes its actionable failure through its snapshot.
    })

    let released = false
    return () => {
      if (released) return
      released = true
      entry.references = Math.max(0, entry.references - 1)
      if (entry.references > 0 || entry.stopTimer) return

      entry.stopTimer = setTimeout(() => {
        entry.stopTimer = null
        if (entry.references > 0) return
        const removeStoppedCore = () => {
          if (
            entry.references === 0 &&
            this.entries.get(core.accountId) === entry
          ) {
            this.entries.delete(core.accountId)
          }
        }
        void core.stop().then(
          removeStoppedCore,
          () => {
            // A failed close can still own the account lock. Retain the core
            // so a remount sees its reload-required snapshot instead of
            // creating a second writer that conflicts with it.
          },
        )
      }, 0)
    }
  }
}

const browserLocks =
  typeof navigator !== "undefined" && navigator.locks
    ? (navigator.locks as unknown as InlineCoreLockManager)
    : undefined
const acquireAccountOwnership =
  createInlineCoreAccountOwnershipAcquirer(browserLocks)

const registry = new InlineAccountCoreRegistry((accountId) => {
  const session = authSession.getState()
  if (
    session.currentUserId !== accountId ||
    session.token == null
  ) {
    throw new Error(
      "Inline account core requires the current authenticated session",
    )
  }
  return new InlineAccountCore(accountId, {
    auth: authSession,
    logger: inlineLog.withScope("Core"),
    acquireAccountOwnership,
  })
})

export const getInlineAccountCore = (accountId: UserID) =>
  registry.get(accountId)

export const retainInlineAccountCore = (
  core: InlineAccountCore,
) => registry.retain(core)
