import { Context, Effect } from "effect"
import type { V1MessagingProvidersContext } from "./v1MessagingOperations.effect"
import type { V1MessagingProvidersOperationError } from "./v1MessagingProvidersErrors.effect"
import type { UploadFileInput, UploadFileResult } from "./v1UploadSchemas.effect"

export interface V1UploadOperationsShape {
  readonly uploadFile: (
    input: UploadFileInput,
    context: V1MessagingProvidersContext,
  ) => Effect.Effect<UploadFileResult, V1MessagingProvidersOperationError>
}

export class V1UploadOperations extends Context.Service<
  V1UploadOperations,
  V1UploadOperationsShape
>()("@inline/server/v1/V1UploadOperations") {}
