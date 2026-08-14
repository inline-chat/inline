import { SESv2Client, SendEmailCommand, type SendEmailCommandInput } from "@aws-sdk/client-sesv2"
import { SES_ACCESS_KEY_ID, SES_REGION, SES_SECRET_ACCESS_KEY } from "@in/server/env"
import { SES_TRANSACTIONAL_REPLY_TO_ADDRESS } from "@in/server/modules/email/transactionalIdentity"

export const sesClient = new SESv2Client({
  credentials: {
    accessKeyId: SES_ACCESS_KEY_ID,
    secretAccessKey: SES_SECRET_ACCESS_KEY,
  },
  region: SES_REGION,
})

type SendEmailContent = {
  subject: string
  text: string
  html?: string
}

export interface SendEmailInput {
  from: "team@inline.chat"
  to: string
  content: SendEmailContent
}

export const sendEmail = async (input: SendEmailInput) => {
  const sesInput: SendEmailCommandInput = {
    Content: {
      Simple: {
        Subject: {
          Data: input.content.subject,
        },
        Body: input.content.html
          ? {
              Html: { Data: input.content.html },
              Text: { Data: input.content.text },
            }
          : { Text: { Data: input.content.text } },
      },
    },
    FromEmailAddress: `"Inline" <${input.from}>`,
    Destination: { ToAddresses: [input.to] },
    ReplyToAddresses: [SES_TRANSACTIONAL_REPLY_TO_ADDRESS],
  }

  return await sesClient.send(new SendEmailCommand(sesInput))
}
