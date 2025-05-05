import { PRELUDE_API_TOKEN } from "@in/server/env"
import Prelude from "@prelude.so/sdk"

const client = new Prelude({
  apiToken: PRELUDE_API_TOKEN ?? "",
})

export async function sendCode(phoneNumber: string) {
  const verification = await client.verification.create({
    target: { type: "phone_number", value: phoneNumber },
  })

  return verification
}

export async function checkCode(phoneNumber: string, code: string) {
  const verification = await client.verification.check({
    target: { type: "phone_number", value: phoneNumber },
    code,
  })

  return verification
}

export const prelude = {
  sendCode,
  checkCode,
}
