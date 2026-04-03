import { createFileRoute, Outlet } from "@tanstack/react-router"

export const Route = createFileRoute("/docs/downloads")({
  component: RouteComponent,
})

function RouteComponent() {
  return <Outlet />
}
