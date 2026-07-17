export const ADMIN_IDLE_MS =
  1000 * 60 * 60 * 24
export const ADMIN_TTL_MS =
  1000 * 60 * 60 * 24 * 3
export const ADMIN_COOKIE_MAX_AGE = Math.floor(
  ADMIN_TTL_MS / 1000,
)
export const ADMIN_STEP_UP_WINDOW_MS =
  1000 * 60 * 15
