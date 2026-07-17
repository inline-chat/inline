import { Layer } from "effect"
import { uploadFileOperation } from "@in/server/methods/uploadFileOperation"
import { makeV1UploadOperations } from "./v1UploadOperationsAdapter.effect"
import { V1UploadOperations } from "./v1UploadOperations.effect"

// TODO(effect-cutover): remove this compatibility Layer once upload storage itself exposes an Effect capability.
export const V1UploadOperationsLive = Layer.succeed(
  V1UploadOperations,
  makeV1UploadOperations((input, context) => uploadFileOperation(input, context)),
)
