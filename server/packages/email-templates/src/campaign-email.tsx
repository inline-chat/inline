import * as React from "react"
import { Body, Container, Head, Html, Img, Preview, Section, Text } from "@react-email/components"
import { Markdown } from "@react-email/markdown"

export interface CampaignEmailProps {
  markdown: string
  previewText?: string | undefined
  unsubscribeUrl?: string | undefined
  visibleUnsubscribe: boolean
}

const fontFamily = "-apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif"

export function CampaignEmail({
  markdown,
  previewText,
  unsubscribeUrl,
  visibleUnsubscribe,
}: CampaignEmailProps) {
  return (
    <Html>
      <Head>
        <meta name="color-scheme" content="light dark" />
        <meta name="supported-color-schemes" content="light dark" />
      </Head>
      {previewText ? <Preview>{previewText}</Preview> : null}
      <Body style={{ margin: 0, padding: 0 }}>
        <Container style={{ padding: "28px 28px 32px", fontFamily, maxWidth: "620px" }}>
          <Img
            src="https://inline.chat/inline-logo-nav@2x.png"
            alt="Inline"
            width="40"
            height="40"
            style={{ display: "block", margin: "0 0 20px" }}
          />
          <Markdown
            markdownContainerStyles={{ fontFamily, fontSize: "16px", lineHeight: "24px" }}
            markdownCustomStyles={{
              h1: { fontSize: "28px", lineHeight: "34px", margin: "24px 0 16px" },
              h2: { fontSize: "22px", lineHeight: "28px", margin: "22px 0 14px" },
              h3: { fontSize: "18px", lineHeight: "24px", margin: "20px 0 12px" },
              p: { fontSize: "16px", lineHeight: "24px", margin: "0 0 14px" },
              link: { color: "#2563eb", textDecoration: "underline" },
              li: { margin: "0 0 6px" },
              codeInline: { backgroundColor: "#f2f3f5", borderRadius: "4px", padding: "2px 4px" },
            }}
          >
            {markdown}
          </Markdown>
          {visibleUnsubscribe && unsubscribeUrl ? (
            <Section style={{ marginTop: "32px" }}>
              <Text style={{ color: "#666", fontSize: "12px", lineHeight: "18px", margin: 0 }}>
                <a href={unsubscribeUrl} style={{ color: "#666" }}>Unsubscribe</a> from campaign emails.
              </Text>
            </Section>
          ) : null}
        </Container>
      </Body>
    </Html>
  )
}
