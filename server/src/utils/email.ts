import { EMAIL_PROVIDER } from "@in/server/config"

import { sendEmail as sendEmailViaSES } from "@in/server/libs/ses"
import { sendEmail as sendEmailViaResend } from "@in/server/libs/resend"

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
  console.log({ content })
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
  console.log({ code, firstName })
  const subject = `Your Inline code: ${code}`
  const text = `
Hey ${firstName ? `${firstName},` : "–"}

Here's your verification code for Inline: ${code}

Inline Team
  `.trim()
  return { subject, text }
}
