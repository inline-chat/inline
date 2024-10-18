// https://effect.website/docs/guides/schema/basic-usage

import { Schema } from "@effect/schema"

/// --------------------
/// Space  -------------
import { DbSpace } from "@in/server/db/schema"

const SpaceInfo = Schema.Struct({
  id: Schema.Int,
  name: Schema.String,
  handle: Schema.NullishOr(Schema.String),
  date: Schema.DateFromNumber,
})
type SpaceInfo = Schema.Schema.Type<typeof SpaceInfo>
type SpaceInfoEncoded = Schema.Schema.Encoded<typeof SpaceInfo>
export const encodeSpaceInfo = (
  space: DbSpace | SpaceInfo,
): SpaceInfoEncoded => {
  return Schema.encodeSync(SpaceInfo)(space)
}
import { t } from "elysia"
export const TSpaceInfo = t.Object({
  id: t.Integer(),
  name: t.String(),
  handle: t.Union([t.Null(), t.String(), t.Undefined()]),
  date: t.Number(),
})
/// --------------------
