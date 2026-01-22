import * as React from "react"
import { Body, Container, Html, Section, Text } from "@react-email/components"

type CodeEmailProps = {
  code: string
  firstName: string | undefined
  isExistingUser: boolean
}

const styles = {
  body: {
    backgroundColor: "#ffffff",
    margin: "0",
    padding: "0",
  },
  container: {
    padding: "28px 28px 32px",
    fontFamily: "-apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif",
    color: "#111111",
  },
  greeting: {
    fontSize: "16px",
    lineHeight: "24px",
    margin: "0 0 16px 0",
  },
  copy: {
    fontSize: "16px",
    lineHeight: "24px",
    margin: "0 0 12px 0",
  },
  codeWrap: {
    display: "inline-block",
    backgroundColor: "#f2f3f5",
    borderRadius: "8px",
    padding: "12px 16px",
  },
  codeText: {
    margin: "0",
    fontSize: "20px",
    lineHeight: "24px",
    letterSpacing: "2px",
    fontFamily:
      "ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, 'Liberation Mono', 'Courier New', monospace",
  },
  signoff: {
    fontSize: "16px",
    lineHeight: "24px",
    margin: "24px 0 0 0",
  },
}

export function CodeEmail({ code, firstName, isExistingUser }: CodeEmailProps) {
  const codeType = isExistingUser ? "login" : "signup"
  const greetingName = firstName ? `${firstName},` : "-"

  return (
    <Html>
      <Body style={styles.body}>
        <Container style={styles.container}>
          <Text style={styles.greeting}>Hey {greetingName}</Text>
          <Text style={styles.copy}>Here's your verification code for Inline {codeType}:</Text>
          <Section style={{ marginBottom: "20px" }}>
            <div style={styles.codeWrap}>
              <Text style={styles.codeText}>{code}</Text>
            </div>
          </Section>
          <Text style={styles.signoff}>Inline Team</Text>
        </Container>
      </Body>
    </Html>
  )
}
