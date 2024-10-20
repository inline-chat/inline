import { Elysia } from "elysia"
import { TMakeApiResponse } from "@in/server/controllers/v1/helpers"
import {
  encode,
  handler,
  Input,
  Response,
} from "@in/server/methods/verifyEmailCode"

export const verifyEmailCodeRoute = new Elysia()
  .get(
    "/verifyEmailCode",
    async ({ query }) => {
      return { ok: true, ...encode(await handler(query, {})) }
    },
    { query: Input, response: TMakeApiResponse(Response) },
  )
  .post(
    "/verifyEmailCode",
    async ({ body }) => {
      return { ok: true, ...encode(await handler(body, {})) }
    },
    { body: Input, response: TMakeApiResponse(Response) },
  )
