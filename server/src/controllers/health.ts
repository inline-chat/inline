import { setup } from "@in/server/setup"
import { Elysia } from "elysia"
import {
  runLivenessCheck,
  runHealthChecks,
  withLifecycleCheck,
  type HealthDeps,
  type HealthLifecycleDeps,
} from "./healthCheck"

export {
  runLivenessCheck,
  runHealthChecks,
  type HealthDeps,
  type HealthHttpResponse,
  type HealthLifecycleDeps,
  type HealthResponse,
  type LivenessHttpResponse,
} from "./healthCheck"

export const createHealthController = (deps?: HealthDeps, lifecycleDeps?: HealthLifecycleDeps) => {
  const readinessHandler = async ({ set }: { set: { status?: number | string } }) => {
    const result = withLifecycleCheck(await runHealthChecks(deps), lifecycleDeps)
    set.status = result.ok ? 200 : 503
    return result
  }

  const livenessHandler = ({ set }: { set: { status?: number | string } }) => {
    const result = runLivenessCheck(lifecycleDeps)
    set.status = result.ok ? 200 : 503
    return result
  }

  const route = (
    path: "/health" | "/healthz" | "/livez" | "/readyz",
    handler: typeof readinessHandler | typeof livenessHandler,
  ) => new Elysia({ name: path.slice(1), prefix: path }).use(setup).get("/", handler)

  return (app: Elysia) => app
    .use(route("/healthz", livenessHandler))
    .use(route("/health", livenessHandler))
    .use(route("/livez", livenessHandler))
    .use(route("/readyz", readinessHandler))
}

export const health = createHealthController()
