import type { Route } from "./+types/home"
import * as stylex from "@stylexjs/stylex"

import { PageMenu } from "../landing/components/PageMenu"
import { PageContainer, PageLongFormContent, PageHeader } from "../landing/components/Page"
import { PageFooter } from "../landing/components/PageFooter"
import { PageMarkdown } from "~/landing/components/PageMarkdown"

import "../landing/styles/style.css"
import "../landing/styles/page-content.css"

export const meta = ({}: Route.MetaArgs) => {
  return [{ title: "Docs - Inline" }]
}

export const links: Route.LinksFunction = () => {
  return []
}

export default function Privacy() {
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
