import { Layer } from "effect"
import {
  getFileByUniqueId,
} from "@in/server/db/models/files"
import { getR2 } from "@in/server/libs/r2"
import {
  decrypt,
} from "@in/server/modules/encryption/encryption"
import {
  FILES_PATH_PREFIX,
  verifySignedMediaFileUrl,
} from "@in/server/modules/files/path"
import {
  MediaOperations,
  makeMediaOperations,
} from "./media.effect"

export const MediaOperationsLive = Layer.succeed(
  MediaOperations,
  makeMediaOperations({
    filesPathPrefix: FILES_PATH_PREFIX,
    verify: verifySignedMediaFileUrl,
    lookup: getFileByUniqueId,
    decryptPath: decrypt,
    getObject: (path) => getR2()?.file(path),
    nowSeconds: () => Math.floor(Date.now() / 1_000),
  }),
)
