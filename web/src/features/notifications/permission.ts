/**
 * Notification permission, asked only from a user gesture, and the one-time
 * "Turn on notifications" affordance.
 *
 * Nothing here prompts on load. `requestPermission` takes the token
 * `userGesture(event)` mints in a click or key handler; without one it
 * resolves to the current state without prompting (the platform enforces the
 * same). The affordance shows while notifications are available, permission
 * has not been decided, and the user has neither dismissed it nor answered it
 * once; dismissal is remembered in the injected storage.
 */

import {
  isUserGesture,
  type Capability,
  type NotificationPermissionState,
  type Notifications,
  type UserGesture,
} from "@inline/platform"
import { computed, signal, type ReadSignal } from "@inline/reactive"

/** `localStorage` or anything with its two methods. Failures are treated as "not stored". */
export type PromptStorage = {
  getItem(key: string): string | null
  setItem(key: string, value: string): void
}

/** Per origin, like the browser permission it is about. */
export const PROMPT_DISMISSED_KEY = "inline:notifications:prompt-dismissed"

export type PermissionState = NotificationPermissionState | "unavailable"

export type PermissionPrompt = {
  /** `unavailable` where the page has no notifications. */
  readonly permission: ReadSignal<PermissionState>
  /** Show the "Turn on notifications" affordance. */
  readonly showPrompt: ReadSignal<boolean>
  /**
   * Ask the browser, from a click or key handler: pass `userGesture(event)`.
   * A null or forged token never prompts. Hides the affordance for good once
   * the browser was asked, whatever the answer.
   */
  requestPermission(gesture: UserGesture | null): Promise<PermissionState>
  /** The user closed the affordance. Remembered. */
  dismiss(): void
}

export type PermissionPromptOptions = {
  readonly notifications: Capability<Notifications>
  readonly storage?: PromptStorage
}

const read = (storage: PromptStorage | undefined): boolean => {
  try {
    return storage?.getItem(PROMPT_DISMISSED_KEY) === "1"
  } catch {
    return false
  }
}

const write = (storage: PromptStorage | undefined) => {
  try {
    storage?.setItem(PROMPT_DISMISSED_KEY, "1")
  } catch {
    // Private mode or quota: the affordance comes back next time, which is harmless.
  }
}

export const createPermissionPrompt = (options: PermissionPromptOptions): PermissionPrompt => {
  const capability = options.notifications
  const dismissed = signal(read(options.storage))
  const permission: ReadSignal<PermissionState> = capability.available
    ? capability.permission
    : { get: () => "unavailable", peek: () => "unavailable" }
  const hide = () => {
    dismissed.set(true)
    write(options.storage)
  }
  return {
    permission,
    showPrompt: computed(() => permission.get() === "default" && !dismissed.get()),
    async requestPermission(gesture) {
      if (!capability.available) return "unavailable"
      if (gesture === null || !isUserGesture(gesture)) return capability.permission.peek()
      const before = capability.permission.peek()
      const after = await capability.requestPermission(gesture)
      if (before === "default") hide()
      return after
    },
    dismiss: hide,
  }
}
