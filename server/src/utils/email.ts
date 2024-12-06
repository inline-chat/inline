import { EMAIL_PROVIDER } from "@in/server/config"

import { sendEmail as sendEmailViaSES } from "@in/server/libs/ses"
import { sendEmail as sendEmailViaResend } from "@in/server/libs/resend"
import { isProd } from "@in/server/env"
import { styleText } from "node:util"
type SendEmailInput = {
  to: string
  content: SendEmailContent
}

type SendEmailContent = CodeTemplateInput
// | {
//     template: "..."
//     variables: {
//       // ...
//     }
//   }

export const sendEmail = async (input: SendEmailInput) => {
  const template = getTemplate(input.content)

  if (!isProd && !process.env["SEND_EMAIL"]) {
    // let's log the email beautifully with formatting, subject, email, from and text so it's easy to read and matches the email

    console.info(
      `
-- email preview -------------------------------
${styleText("blueBright", "Subject:")} ${template.subject}
${styleText("blueBright", "To:")} ${input.to}

${template.text}

${styleText("cyan", "[Preview email. Force sending via SEND_EMAIL=1]")}
------------------------------------------------
    `.trim(),
    )
    return
  }

  if (EMAIL_PROVIDER === "SES") {
    await sendEmailViaSES({
      to: input.to,
      from: "team@inline.chat",
      content: {
        type: "text",
        subject: template.subject,
        text: template.text,
      },
    })
  } else {
    let result = await sendEmailViaResend({
      from: "Inline <team@inline.chat>",
      to: input.to,
      subject: template.subject,
      text: template.text,
      replyTo: "team@inline.chat",
    })

    if (result.error) {
      throw result.error
    }
  }
}

// ----------------------------------------------------------------------------
// Templates
// ----------------------------------------------------------------------------
interface TemplateInput {
  template: string
  variables: Record<string, unknown>
}

type TextTemplate = {
  subject: string
  text: string
}

const getTemplate = (content: SendEmailContent): TextTemplate => {
  switch (content.template) {
    case "code":
      return CodeTemplate(content.variables)
  }
}

interface CodeTemplateInput extends TemplateInput {
  template: "code"
  variables: { code: string; firstName: string | undefined }
}
function CodeTemplate({ code, firstName }: CodeTemplateInput["variables"]): TextTemplate {
  const subject = `Your Inline code: ${code}`
  const text = `
Hey ${firstName ? `${firstName},` : "–"}

Here's your verification code for Inline: ${code}

Inline Team
  `.trim()
  return { subject, text }
}
