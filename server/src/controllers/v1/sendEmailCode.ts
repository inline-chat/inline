import { Elysia } from "elysia"
import { TMakeApiResponse } from "@in/server/controllers/v1/helpers"
import {
  encodeSendEmailCode,
  sendEmailCode,
  SendEmailCodeInput,
  SendEmailResponse,
} from "@in/server/methods/sendEmailCode"

export const sendEmailCodeRoute = new Elysia()
  .get(
    "/sendEmailCode",
    async ({ query }) => {
      let result = encodeSendEmailCode(await sendEmailCode(query, {}))
      return { ok: true, ...result }
    },
    {
      query: SendEmailCodeInput,
      response: TMakeApiResponse(SendEmailResponse),
    },
  )
  .post(
    "/sendEmailCode",
    async ({ body }) => {
      let result = encodeSendEmailCode(await sendEmailCode(body, {}))
      return { ok: true, ...result }
    },
    {
      body: SendEmailCodeInput,
      response: TMakeApiResponse(SendEmailResponse),
    },
  )
