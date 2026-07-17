import { Layer } from "effect"
import {
  insertThereUser,
} from "@in/server/db/models/there"
import {
  ThereOperations,
  makeThereOperations,
} from "./there.effect"

export const ThereOperationsLive = Layer.succeed(
  ThereOperations,
  makeThereOperations(insertThereUser),
)
