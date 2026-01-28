import * as React from "react"
import { Body, Container, Head, Html, Img, Section, Text } from "@react-email/components"

type CodeEmailProps = {
  code: string
  firstName: string | undefined
  isExistingUser: boolean
}

const styles = {
  body: {
    margin: "0",
    padding: "0",
  },
  container: {
    padding: "28px 28px 32px",
    fontFamily: "-apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif",
  },
  logo: {
    display: "block",
    margin: "0 0 20px 0",
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
    borderRadius: "12px",
    padding: "16px 20px",
  },
  codeText: {
    margin: "0",
    fontSize: "24px",
    lineHeight: "28px",
    letterSpacing: "2px",
    textAlign: "center",
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
  const greeting = firstName ? `Hey ${firstName},` : "Hey,"

  return (
    <Html>
      <Head>
        <meta name="color-scheme" content="light dark" />
        <meta name="supported-color-schemes" content="light dark" />
      </Head>
      <Body style={styles.body}>
        <Container style={styles.container}>
          <Img
            src="https://inline.chat/inline-logo-nav@2x.png"
            alt="Inline"
            width="40"
            height="40"
            style={styles.logo}
          />
          <Text style={styles.greeting}>{greeting}</Text>
          <Text style={styles.copy}>Here's your verification code for Inline {codeType}:</Text>
          <Section style={{ margin: "20px 0" }}>
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
