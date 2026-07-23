import { Outlet } from "@tanstack/react-router"

/**
 * TanStack owns route preparation and commit timing. This cover has one
 * narrower job: prevent the previously resolved detail from appearing under
 * a new chat URL while React commits the next match.
 */
export function AppRouteOutlet() {
  return <Outlet />
}
