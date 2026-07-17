import type { V1MessagingProvidersContext } from "./v1MessagingOperations.effect"
import { invokeLegacyV1Operation } from "./v1MessagingProvidersOperationsAdapter.effect"
import type { V1UploadOperationsShape } from "./v1UploadOperations.effect"
import { UploadFileResult, type UploadFileInput } from "./v1UploadSchemas.effect"

export const makeV1UploadOperations = (
  upload: (
    input: UploadFileInput,
    context: V1MessagingProvidersContext,
  ) => Promise<unknown>,
): V1UploadOperationsShape => ({
  uploadFile: (input, context) =>
    invokeLegacyV1Operation("v1.uploadFile", UploadFileResult, () => upload(input, context)),
})
