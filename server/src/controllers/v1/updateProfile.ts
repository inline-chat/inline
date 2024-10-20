import { Elysia } from "elysia"
import { TMakeApiResponse } from "@in/server/controllers/v1/helpers"
import {
  encode,
  handler,
  Input,
  Response,
} from "@in/server/methods/updateProfile"
import { authenticate } from "@in/server/controllers/plugins"

export const updateProfileRoute = new Elysia()
  .use(authenticate)
  .get(
    "/updateProfile",
    async ({ query, store: { currentUserId } }) => {
      return { ok: true, ...encode(await handler(query, { currentUserId })) }
    },
    { query: Input, response: TMakeApiResponse(Response) },
  )
  .post(
    "/updateProfile",
    async ({ body, store: { currentUserId } }) => {
      return { ok: true, ...encode(await handler(body, { currentUserId })) }
    },
    { body: Input, response: TMakeApiResponse(Response) },
  )
