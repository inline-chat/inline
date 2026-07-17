import { setup } from "@in/server/setup"
import { Elysia } from "elysia"
import {
  runHealthChecks,
  withLifecycleCheck,
  type HealthDeps,
  type HealthLifecycleDeps,
} from "./healthCheck"

export {
  runHealthChecks,
  type HealthDeps,
  type HealthHttpResponse,
  type HealthLifecycleDeps,
  type HealthResponse,
} from "./healthCheck"

export const createHealthController = (deps?: HealthDeps, lifecycleDeps?: HealthLifecycleDeps) => {
  const healthHandler = async ({ set }: { set: { status?: number | string } }) => {
    const result = withLifecycleCheck(await runHealthChecks(deps), lifecycleDeps)
    set.status = result.ok ? 200 : 503
    return result
  }

  const route = (path: "/health" | "/healthz") =>
    new Elysia({ name: path.slice(1), prefix: path }).use(setup).get("/", healthHandler)

  return (app: Elysia) => app.use(route("/healthz")).use(route("/health"))
}

export const health = createHealthController()
