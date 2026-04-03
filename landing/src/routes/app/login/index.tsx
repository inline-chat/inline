import { createFileRoute, Link, Navigate, Outlet, useNavigate, useRouter } from "@tanstack/react-router"

export const Route = createFileRoute("/app/login/")({
  component: RouteComponent,
})

function RouteComponent() {
  return <Navigate to="/app/login/welcome" />
}
