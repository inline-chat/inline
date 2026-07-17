import {
  t,
  type TSchema,
} from "elysia"

export const TMakeApiResponse = <T extends TSchema>(
  type: T,
) => {
  const success = t.Object({
    ok: t.Literal(true),
    result: type,
  })
  const failure = t.Object({
    ok: t.Literal(false),
    error: t.String(),
    errorCode: t.Optional(t.Number()),
    description: t.Optional(t.String()),
  })

  return t.Union([success, failure])
}
