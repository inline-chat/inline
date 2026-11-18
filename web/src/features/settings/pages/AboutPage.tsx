/** About: the build, the update waiting (with Reload to Update), and the legal links. */

import type { Platform } from "@inline/platform"
import { useSignal } from "@inline/reactive/react"
import { Button } from "@inline/ui/react"
import { color } from "@inline/ui/tokens/color.stylex"
import { font } from "@inline/ui/tokens/font.stylex"
import { radius } from "@inline/ui/tokens/radius.stylex"
import { size } from "@inline/ui/tokens/size.stylex"
import { space } from "@inline/ui/tokens/space.stylex"
import * as stylex from "@stylexjs/stylex"
import type { MouseEvent } from "react"
import { updateCopy } from "../format"
import { Note, Row, Section } from "../Rows"
import type { SettingsModel } from "../settings-model"
import { PRIVACY_URL, TERMS_URL } from "../types"

export function AboutPage(props: { model: SettingsModel; platform: Platform; buildId: string }) {
  const { platform } = props
  const update = updateCopy(useSignal(platform.updater.state))
  // Links keep their address (copy, middle click) but open through the platform's checked capability.
  const openExternal = (event: MouseEvent<HTMLAnchorElement>) => {
    event.preventDefault()
    platform.links.openExternal(event.currentTarget.href)
  }
  return (
    <>
      <Section title="Inline">
        <Row
          model={props.model}
          item="version"
          control={() => (
            <span dir="ltr" {...stylex.props(styles.build)}>
              {props.buildId}
            </span>
          )}
        />
      </Section>

      <Section title="Updates">
        <Row
          model={props.model}
          item="softwareUpdate"
          control={({ titleId }) => (
            <>
              <Note live>{update.status}</Note>
              {update.canApply ? (
                <Button variant="primary" aria-describedby={titleId} onClick={() => platform.updater.apply()}>
                  Reload to Update
                </Button>
              ) : null}
            </>
          )}
        />
      </Section>

      <Section title="Legal">
        <Row
          model={props.model}
          item="legal"
          control={() => (
            <span {...stylex.props(styles.links)}>
              <a href={TERMS_URL} target="_blank" rel="noopener noreferrer" onClick={openExternal} {...stylex.props(styles.link)}>
                Terms of Service
              </a>
              <a href={PRIVACY_URL} target="_blank" rel="noopener noreferrer" onClick={openExternal} {...stylex.props(styles.link)}>
                Privacy Policy
              </a>
            </span>
          )}
        />
      </Section>
    </>
  )
}

const styles = stylex.create({
  build: {
    fontFamily: font.familyMono,
    fontSize: font.sizeCallout,
    color: color.secondaryLabel,
    userSelect: "text",
  },
  links: { display: "flex", flexWrap: "wrap", gap: space.lg },
  link: {
    fontSize: font.sizeBody,
    color: color.link,
    textDecoration: { default: "none", ":hover": "underline" },
    borderRadius: radius.small,
    outline: { default: "none", ":focus-visible": `${size.focusRingWidth} solid ${color.focusRing}` },
    outlineOffset: "1px",
  },
})
