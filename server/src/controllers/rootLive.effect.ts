import { Effect, Layer } from "effect"
import {
  gitCommitHash,
  relativeBuildDate,
  version,
} from "@in/server/buildEnv"
import {
  RootPageOperations,
} from "./root.effect"
import {
  renderRootDocument,
} from "./rootPage"

export const RootPageOperationsLive = Layer.succeed(
  RootPageOperations,
  {
    document: Effect.sync(() =>
      renderRootDocument({
        gitCommitHash,
        relativeBuildDate: relativeBuildDate(),
        version,
      }),
    ),
  },
)
