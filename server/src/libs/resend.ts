import { RESEND_API_KEY } from "@in/server/env"
import { Resend, type CreateEmailOptions } from "resend"

export const resend = new Resend(RESEND_API_KEY)

export const sendEmail = async (input: CreateEmailOptions) => {
  return await resend.emails.send(input)
}
