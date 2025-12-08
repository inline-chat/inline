import * as stylex from "@stylexjs/stylex"

import { PageMenu } from "../landing/components/PageMenu"
import { PageContainer, PageLongFormContent, PageHeader } from "../landing/components/Page"
import { PageFooter } from "../landing/components/PageFooter"
import { PageMarkdown } from "~/landing/components/PageMarkdown"

import styleCssUrl from "../landing/styles/style.css?url"
import "../landing/styles/page-content.css"
import { createFileRoute } from "@tanstack/react-router"

// return [{ title: "Docs - Inline" }]

export const Route = createFileRoute("/docs")({
  component: Docs,

  head: () => ({
    links: [{ rel: "stylesheet", href: styleCssUrl }],
  }),
})

function Docs() {
  return (
    <>
      <PageMenu />

      <PageContainer>
        <PageHeader title="Docs" />
        <PageLongFormContent>
          <PageMarkdown className="page-content">{PRIVACY_POLICY}</PageMarkdown>
        </PageLongFormContent>
      </PageContainer>

      <PageFooter />
    </>
  )
}

const styles = stylex.create({})

const PRIVACY_POLICY = `
WIP
`
