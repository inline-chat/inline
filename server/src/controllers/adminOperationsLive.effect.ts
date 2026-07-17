import {
  Effect,
  Layer,
} from "effect"
import {
  makeAdminAuthOperations,
} from "./adminAuthOperationsLive.effect"
import {
  makeAdminManagementOperations,
} from "./adminManagementOperationsLive.effect"
import {
  makeAdminMetricsOperations,
} from "./adminMetricsOperationsLive.effect"
import {
  AdminOperations,
} from "./adminOperations.effect"
import {
  AdminSessionStore,
} from "./adminSecurity.effect"

export const AdminOperationsLive = Layer.effect(
  AdminOperations,
  Effect.gen(function* () {
    const sessionStore = yield* AdminSessionStore
    return {
      ...makeAdminAuthOperations(sessionStore),
      ...makeAdminMetricsOperations(),
      ...makeAdminManagementOperations(),
    }
  }),
)
