import {
  Context,
  Effect,
  Schema,
} from "effect"
import {
  HttpServerResponse,
} from "effect/unstable/http"
import {
  HttpApiEndpoint,
  HttpApiSchema,
} from "effect/unstable/httpapi"

export const AuxiliaryRootHtml = Schema.String.pipe(
  HttpApiSchema.asText({
    contentType: "text/html; charset=utf8",
  }),
).annotate({
  identifier: "AuxiliaryRootHtml",
})

export const RootEndpoints = {
  root: HttpApiEndpoint.get(
    "auxiliaryRoot",
    "/",
    {
      success: AuxiliaryRootHtml,
    },
  ),
} as const

export interface RootPageOperationsShape {
  readonly document: Effect.Effect<string>
}

export class RootPageOperations extends Context.Service<
  RootPageOperations,
  RootPageOperationsShape
>()("@inline/server/auxiliary/RootPageOperations") {}

export const executeRoot = RootPageOperations.use(
  (operations) =>
    operations.document.pipe(
      Effect.map((document) =>
        HttpServerResponse.raw(
          new TextEncoder().encode(document),
          {
            headers: {
              "content-type":
                "text/html; charset=utf8",
            },
          },
        ),
      ),
    ),
)
