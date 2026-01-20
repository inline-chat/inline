import { createRootRoute, Outlet } from "@tanstack/react-router"

const Root = () => (
  <div className="min-h-screen bg-background text-foreground">
    <Outlet />
  </div>
)

export const Route = createRootRoute({
  component: Root,
})
