import { SESv2Client, SendEmailCommand, type SendEmailCommandInput } from "@aws-sdk/client-sesv2"
import { AMAZON_ACCESS_KEY, AMAZON_SECRET_ACCESS_KEY } from "@in/server/env"

export const sesClient = new SESv2Client({
  credentials: {
    accessKeyId: AMAZON_ACCESS_KEY,
    secretAccessKey: AMAZON_SECRET_ACCESS_KEY,
  },
  region: "us-east-1",
})

type SendEmailContent =
  | {
      type: "html"
      subject: string
      html: string
    }
  | {
      type: "text"
      subject: string
      text: string
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
        Body:
          input.content.type === "html"
            ? { Html: { Data: input.content.html } }
            : { Text: { Data: input.content.text } },
      },
    },
    FromEmailAddress: `"Inline" <${input.from}>`,
    Destination: { ToAddresses: [input.to] },
    ReplyToAddresses: ["hi@inline.chat"],
  }

  return await sesClient.send(new SendEmailCommand(sesInput))
}
