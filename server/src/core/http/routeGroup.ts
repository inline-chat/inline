import type { Layer } from "effect"
import type { HttpApiGroup } from "effect/unstable/httpapi"

export type HttpApiDocument = "platform" | "bot"

/**
 * Stable contract exported by a route-family slice.
 *
 * The handler factory stays separately typed against the shared API base. This
 * descriptor gives the integration owner enough information to add the group
 * to the correct executable API without letting a slice edit shared aggregates.
 */
export interface HttpRouteGroupDefinition<
  ApiId extends string,
  Group extends HttpApiGroup.Constraint,
  HandlersError,
  HandlersRequirements,
> {
  readonly apiId: ApiId
  readonly document: HttpApiDocument
  readonly group: Group
  readonly handlers: Layer.Layer<
    HttpApiGroup.Service<ApiId, Group["identifier"]>,
    HandlersError,
    HandlersRequirements
  >
}

export const defineHttpRouteGroup = <
  ApiId extends string,
  Group extends HttpApiGroup.Constraint,
  HandlersError,
  HandlersRequirements,
>(
  definition: HttpRouteGroupDefinition<
    ApiId,
    Group,
    HandlersError,
    HandlersRequirements
  >,
): HttpRouteGroupDefinition<
  ApiId,
  Group,
  HandlersError,
  HandlersRequirements
> => definition
