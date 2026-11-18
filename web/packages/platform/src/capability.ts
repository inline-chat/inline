/**
 * A capability is either available, with its methods, or explicitly
 * unavailable with a reason. Callers check `available` and hide the feature
 * instead of calling something that fails.
 *
 * ```ts
 * if (platform.files.reveal.available) platform.files.reveal.reveal(path)
 * ```
 */

export type Unavailable = {
  readonly available: false
  /** Why, for diagnostics and settings copy. Not shown as an error. */
  readonly reason: string
}

export type Available<T> = T & { readonly available: true }

export type Capability<T> = Available<T> | Unavailable

export const unavailable = (reason: string): Unavailable => ({ available: false, reason })

export const available = <T extends object>(value: T): Available<T> => ({ ...value, available: true })

/** Reason used for every desktop-only capability in a browser. */
export const DESKTOP_ONLY = "desktop-only"
