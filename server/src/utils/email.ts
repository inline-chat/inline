import { EMAIL_PROVIDER } from "@in/server/config"

import { sendEmail as sendEmailViaSES } from "@in/server/libs/ses"
import { sendEmail as sendEmailViaResend } from "@in/server/libs/resend"
import { isProd } from "@in/server/env"
import { styleText } from "node:util"
import { Log } from "@in/server/utils/log"
import type { UserName } from "@in/server/modules/cache/userNames"
type SendEmailInput = {
  to: string
  content: SendEmailContent
}

/**
 * The content of the email to send
 *
 * @see CodeTemplateInput
 * @see InvitedToSpaceTemplateInput
 */
type SendEmailContent = CodeTemplateInput | InvitedToSpaceTemplateInput | AdminActionTemplateInput

export const sendEmail = async (input: SendEmailInput) => {
  const template = getTemplate(input.content)

  if (!isProd && !process.env["SEND_EMAIL"]) {
    // let's log the email beautifully with formatting, subject, email, from and text so it's easy to read and matches the email

    Log.shared.info(
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
      replyTo: "founders@inline.chat",
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

    case "invitedToSpace":
      return InvitedToSpaceTemplate(content.variables)

    case "adminAction":
      return AdminActionTemplate(content.variables)
  }
}

interface CodeTemplateInput extends TemplateInput {
  template: "code"
  variables: {
    code: string
    firstName: string | undefined
    isExistingUser: boolean
  }
}

interface InvitedToSpaceTemplateInput extends TemplateInput {
  template: "invitedToSpace"
  variables: {
    email: string
    spaceName: string
    isExistingUser: boolean
    firstName: string | undefined
    invitedByUserName: UserName | undefined
  }
}

interface AdminActionTemplateInput extends TemplateInput {
  template: "adminAction"
  variables: {
    actionTaken: string
    actorEmail: string
    ip?: string | null
    userAgent?: string | null
    timestamp: string
  }
}

function CodeTemplate({ code, firstName, isExistingUser }: CodeTemplateInput["variables"]): TextTemplate {
  const codeType = isExistingUser ? "login" : "signup"
  const subject = `Your Inline ${codeType} code: ${code}`
  const text = `
Hey ${firstName ? `${firstName},` : "-"}

Here's your verification code for Inline ${codeType}: ${code}

Inline Team
  `.trim()
  return { subject, text }
}

function InvitedToSpaceTemplate({
  email,
  spaceName,
  isExistingUser,
  firstName,
  invitedByUserName,
}: InvitedToSpaceTemplateInput["variables"]): TextTemplate {
  const subject = `You've been invited to "${spaceName}"`
  const invitedByName = invitedByUserName
    ? `by "${invitedByUserName.firstName ?? invitedByUserName.username ?? invitedByUserName.email}"`
    : ""
  const text = `
Hey ${firstName ? `${firstName},` : "-"}

You've been invited to join "${spaceName}" ${invitedByName} on Inline.

${
  isExistingUser
    ? `You can start chatting by opening the Inline app. Make sure you're logged in with the email: ${email}.`
    : `
To start chatting, get the app from TestFlight from one of the links below. Then, sign up via your email: "${email}".

For iPhone/iPad: https://testflight.apple.com/join/FkC3f7fz
(Here's a video showing how to install: https://www.loom.com/share/73f951f0963843f588c921751ac82603)

For Mac: https://testflight.apple.com/join/Z8zUcWZH
    `
}
  `.trim()
  return { subject, text }
}

function AdminActionTemplate({
  actionTaken,
  actorEmail,
  ip,
  userAgent,
  timestamp,
}: AdminActionTemplateInput["variables"]): TextTemplate {
  const subject = `Inline admin activity: ${actionTaken}`
  const text = `
Admin activity detected.

Action: ${actionTaken}
Actor: ${actorEmail}
Time: ${timestamp}
IP: ${ip ?? "unknown"}
User agent: ${userAgent ?? "unknown"}

If this wasn't you, rotate credentials immediately.

Inline Team
  `.trim()

  return { subject, text }
}
