import * as React from "react"
import { CodeEmail } from "@inline-chat/email-templates"

export type EmailTemplate = {
  id: string
  name: string
  component: React.ComponentType<Record<string, unknown>>
  props: Record<string, unknown>
}

export const templates: EmailTemplate[] = [
  {
    id: "code-email",
    name: "Login code",
    component: CodeEmail as React.ComponentType<Record<string, unknown>>,
    props: {
      code: "123456",
      firstName: "Mo",
      isExistingUser: true,
    },
  },
]
