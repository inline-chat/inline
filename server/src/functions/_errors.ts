import { Data } from "effect"

export class SpaceIdInvalidError extends Data.TaggedError("functions/SpaceIdInvalid")<{}> {}
export class SpaceNotExistsError extends Data.TaggedError("functions/SpaceNotExists")<{}> {}
