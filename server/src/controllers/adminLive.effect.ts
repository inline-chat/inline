import {
  Layer,
} from "effect"
import {
  AdminRouteGroup,
} from "./admin.effect"
import {
  AdminOperationsLive,
} from "./adminOperationsLive.effect"
import {
  AdminSessionStoreLive,
  AdminSecurityLive,
} from "./adminSecurityLive.effect"

export const AdminRouteGroupLive =
  AdminRouteGroup.handlers.pipe(
    Layer.provide(
      Layer.merge(
        AdminOperationsLive,
        AdminSecurityLive,
      ).pipe(
        // Middleware performs the lookup in request scope, so the store must
        // remain in the served graph after building the operation services.
        Layer.provideMerge(AdminSessionStoreLive),
      ),
    ),
  )
