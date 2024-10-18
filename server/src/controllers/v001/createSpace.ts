import { Elysia, t, TSchema } from "elysia"
import { type TObject } from "@sinclair/typebox"
import { setup } from "@in/server/setup"
import { createSpace, CreateSpaceInput } from "@in/server/methods/createSpace"
import { encodeSpaceInfo, TSpaceInfo } from "@in/server/models"

const TMakeApiResponse = <T extends TSchema>(type: T) =>
  t.Union([
    t.Composite([t.Object({ ok: t.Literal(true) }), type]),
    t.Object({
      ok: t.Literal(false),
      errorCode: t.Number(),
      description: t.Optional(t.String()),
    }),
  ])

export const createSpaceRoute = new Elysia()
  .get(
    "/createSpace",
    async ({ query }) => {
      let spaceRaw = await createSpace(query)
      let space = encodeSpaceInfo(spaceRaw)
      return { ok: true, space }
    },
    {
      query: CreateSpaceInput,
      response: TMakeApiResponse(t.Object({ space: TSpaceInfo })),
    },
  )
  .post(
    "/createSpace",
    async ({ body }) => {
      let spaceRaw = await createSpace(body)
      let space = encodeSpaceInfo(spaceRaw)
      return { ok: true, space }
    },
    {
      body: CreateSpaceInput,
      response: TMakeApiResponse(t.Object({ space: TSpaceInfo })),
    },
  )
