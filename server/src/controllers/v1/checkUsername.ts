import { Elysia } from "elysia"
import { TMakeApiResponse } from "@in/server/controllers/v1/helpers"
import {
  encode,
  handler,
  Input,
  Response,
} from "@in/server/methods/checkUsername"
import { authenticate } from "@in/server/controllers/plugins"

export const checkUsernameRoute = new Elysia()
  .use(authenticate)
  .get(
    "/checkUsername",
    async ({ query, store: { currentUserId } }) => {
      return { ok: true, ...encode(await handler(query, { currentUserId })) }
    },
    { query: Input, response: TMakeApiResponse(Response) },
  )
  .post(
    "/checkUsername",
    async ({ body, store: { currentUserId } }) => {
      return { ok: true, ...encode(await handler(body, { currentUserId })) }
    },
    { body: Input, response: TMakeApiResponse(Response) },
  )
