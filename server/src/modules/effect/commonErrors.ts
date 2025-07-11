import { Data } from "effect"

export class MemberNotExistsError extends Data.TaggedError("commonErrors/MemberNotExists")<{}> {}
