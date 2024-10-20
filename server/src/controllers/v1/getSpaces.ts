import { Elysia } from "elysia"
import { TMakeApiResponse } from "@in/server/controllers/v1/helpers"
import { encode, handler, Input, Response } from "@in/server/methods/getSpaces"
import { authenticate } from "@in/server/controllers/plugins"

export const getSpacesRoute = new Elysia()
  .use(authenticate)
  .get(
    "/getSpaces",
    async ({ query, store: { currentUserId } }) => {
      return { ok: true, ...encode(await handler(query, { currentUserId })) }
    },
    { query: Input, response: TMakeApiResponse(Response) },
  )
  .post(
    "/getSpaces",
    async ({ body, store: { currentUserId } }) => {
      return { ok: true, ...encode(await handler(body, { currentUserId })) }
    },
    { body: Input, response: TMakeApiResponse(Response) },
  )
