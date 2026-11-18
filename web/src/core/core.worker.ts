/// <reference lib="webworker" />
/**
 * The account core's dedicated worker. It owns the replica (SQLite on OPFS)
 * and the connection; UI contexts reach it through `@inline/link`.
 */
import { CoreHost, openOpfsHostStorage } from "@inline/client/host"
import { getServerUrl } from "@inline/config"
import { serveCore } from "@inline/link"
import { BUILD_ID } from "./build"

/** Separates replicas of one account ID that belong to different servers. */
const storageNamespace = () => {
  try {
    return new URL(getServerUrl()).host
  } catch {
    return "default"
  }
}

serveCore(self, () => {
  const namespace = storageNamespace()
  const host = new CoreHost({
    buildId: BUILD_ID,
    openStorage: (userId) => openOpfsHostStorage(userId, { namespace }),
  })
  return {
    open: () => host.openContext(),
    close: () => host.close(),
  }
})
