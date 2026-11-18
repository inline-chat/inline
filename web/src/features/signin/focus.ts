/**
 * Focus helpers for the sign-in steps. Framework-free DOM functions; the
 * views use them as ref callbacks and from event handlers, never from effects.
 */

/**
 * A ref callback that focuses its element when it mounts. Defined once at
 * module level so its identity never changes and React calls it only on
 * mount and unmount, not on every render. Each step mounts fresh (the screen
 * keys the step), so this is "focus the step's first field when the step
 * changes".
 */
export const focusOnMount = (element: HTMLElement | null): void => {
  if (element && element.ownerDocument.activeElement !== element) {
    element.focus()
  }
}

/**
 * After a request comes back with an error, put focus back in the step's
 * field (the submit control was disabled while it ran, which can drop
 * focus). Does nothing when the form has gone, because the step moved on.
 */
export const focusFieldAfterError = (
  form: HTMLFormElement | null,
  options: { select?: boolean } = {},
): void => {
  if (!form || !form.isConnected) return
  const input = form.querySelector<HTMLInputElement>("input:not([type=hidden])")
  if (!input) return
  input.focus()
  if (options.select) input.select()
}
