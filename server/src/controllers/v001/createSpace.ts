import { Elysia, t } from "elysia"
import { setup } from "@in/server/setup"
import { createSpace, CreateSpaceInput } from "@in/server/methods/createSpace"
import { encodeSpaceInfo } from "@in/server/models"

export const createSpaceRoute = new Elysia()
  .get(
    "/createSpace",
    async ({ query }) => {
      let spaceRaw = await createSpace(query)
      let space = encodeSpaceInfo(spaceRaw)
      return { ok: true, space }
    },
    { query: CreateSpaceInput },
  )
  .post(
    "/createSpace",
    async ({ body }) => {
      let spaceRaw = await createSpace(body)
      let space = encodeSpaceInfo(spaceRaw)
      return { ok: true, space }
    },
    { body: CreateSpaceInput },
  )
