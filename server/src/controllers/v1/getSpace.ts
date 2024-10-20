import { Elysia } from "elysia"
import { TMakeApiResponse } from "@in/server/controllers/v1/helpers"
import { authenticate } from "@in/server/controllers/plugins"
import { encode, handler, Input, Response } from "@in/server/methods/getSpace"

export const getSpaceRoute = new Elysia()
  .use(authenticate)
  .get(
    "/getSpace",
    async ({ query, store: { currentUserId } }) => {
      return { ok: true, ...encode(await handler(query, { currentUserId })) }
    },
    { query: Input, response: TMakeApiResponse(Response) },
  )
  .post(
    "/getSpace",
    async ({ body, store: { currentUserId } }) => {
      return { ok: true, ...encode(await handler(body, { currentUserId })) }
    },
    { body: Input, response: TMakeApiResponse(Response) },
  )
